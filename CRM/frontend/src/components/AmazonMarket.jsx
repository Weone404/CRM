import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { Modal } from './AmazonDecisions';
import { inr, ageText } from '../utils/amazon';

// CRM > Amazon > Keywords and Competitors.
// Keywords: ideas from the competitors ranked above us, Claude (spellings, related, gifting), festivals, and your own.
// Each keyword: apply to every product / selected products, edit, remove. Changes go to Decisions; nothing goes live by itself.
// Competitors: every morning, only the products ranked ABOVE ours for each watched keyword (at #1: the two just below).

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function edge(name, body) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` },
    body: JSON.stringify(body) });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
function useData(fn) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const load = useCallback(() => fn().then((x) => { setD(x); setErr(''); }).catch((e) => setErr(e.message)), [fn]);
  useEffect(() => { load(); }, [load]);
  return [d, load, err];
}
const Chip = ({ children, style, title }) => (
  <span title={title} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: 'rgba(118,118,128,0.14)', color: '#3C3C43', ...style }}>{children}</span>
);
const Empty = ({ children }) => <div className="text-center text-glass-muted py-10 text-sm">{children}</div>;
const GREEN = { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' };
const BLUE = { background: 'rgba(0,122,255,0.12)', color: '#0062CC' };
const AMBER = { background: 'rgba(255,149,0,0.14)', color: '#B25E00' };
const RED = { background: 'rgba(255,59,48,0.12)', color: '#C4261D' };
const PURPLE = { background: 'rgba(175,82,222,0.12)', color: '#8E3CB8' };

const SOURCE = {
  competitor: ['From competitors', BLUE], claude: ['Claude', PURPLE], festival: ['Festival', AMBER], user: ['Added by you', GREEN],
  catalog: ['From your names', {}], ads: ['From ads', {}],
};
const KIND = { spelling: 'Spelling', related: 'Related', gift: 'Gift', search: 'Search', festival: 'Festival', niche: 'Own niche' };
const PLACES = [
  ['auto', 'Auto (recommended)', 'Claude decides: main keywords go into the name and Item Highlights, the rest into hidden search words.'],
  ['name', 'Product name', 'Claude drafts names that carry it (strongest for ranking). No hidden-words change.'],
  ['highlights', 'Name + Item Highlights', 'Hidden search words now, and Claude drafts a name / Item Highlights with it.'],
  ['hidden', 'Hidden search words only', 'Only the missing words, never visible to shoppers.'],
];
const fmtDay = (d) => (d ? new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' }).format(new Date(d)) : '');
const STATUS = {
  live: ['Live', GREEN], pending: ['Waiting in Decisions', AMBER], covered: ['Already findable', GREEN], no_room: ['No room', RED],
  removing: ['Removal waiting', AMBER], removed: ['Removed', {}], rejected: ['Not applied', {}],
  not_fit: ["Doesn't fit", {}], lost: ['Lost after a name change', RED],
};
const EFFECT = { working: ['Working ↑', GREEN], no_effect: ['No effect yet', {}], too_early: ['Checking (14 days)', {}] };
const rankText = (r) => (r == null ? 'Not in top 20' : `#${r}`);
function Trend({ now, before, had }) {
  if (!had) return null;                                   // first check: nothing to compare with
  if (now == null && before == null) return null;
  if (before == null && now != null) return <span className="text-[11px] font-semibold" style={{ color: '#1E7B34' }}>new in top 20</span>;
  if (now == null) return <span className="text-[11px] font-semibold" style={{ color: '#C4261D' }}>dropped out</span>;
  if (now === before) return <span className="text-[11px] text-glass-muted">same</span>;
  const up = now < before;
  return <span className="text-[11px] font-semibold" style={{ color: up ? '#1E7B34' : '#C4261D' }}>{up ? '▲' : '▼'} {Math.abs(now - before)}</span>;
}
const bytesOf = (s) => new TextEncoder().encode(s || '').length;

// ---------------------------------------------------------------- product picker (apply / remove on selected products)
const PICK = {
  smart: ['Smart apply', 'Add to', 'Checks each product fits. Missing words go into hidden search words; for main keywords Claude also drafts names with it. All wait in Decisions.'],
  hidden: ['Hidden words only', 'Add to', 'Only the missing words go into hidden search words, never over the byte limit. One Decision per product.'],
  name: ['Suggest better name', 'Ask Claude for', 'Claude drafts 2 names (74 letters max) with Item Highlights for each product. They wait in Decisions next to the current choices.'],
  remove: ['Remove', 'Remove from', 'Removes its words from hidden search words (words other keywords need are kept).'],
};
function ProductPicker({ data, kw, mode, onClose, onDone }) {
  const rows = kw.products || [];
  const statusOf = (sku) => rows.find((r) => r.sku === sku)?.status;
  const can = (p) => (mode === 'remove' ? ['live', 'pending', 'covered', 'no_room', 'rejected', 'not_fit', 'lost'].includes(statusOf(p.sku)) : true);
  const products = data.products.filter(can);
  const [fit, setFit] = useState(mode === 'remove' ? {} : null);
  useEffect(() => { if (mode !== 'remove') rpc('api_amz_keyword_fit', { p_id: kw.id }).then((f) => setFit(f || {})).catch(() => setFit({})); }, [kw.id, mode]);
  const bad = (sku) => (fit ? fit[sku] : null);
  const [sel, setSel] = useState(() => new Set());
  const [preset, setPreset] = useState(false);
  useEffect(() => { // own niche: its group is chosen for you (only products it fits)
    if (preset || !fit || mode === 'remove' || !kw.target_skus?.length) return;
    setSel(new Set(kw.target_skus.filter((x) => !fit[x]))); setPreset(true);
  }, [fit, preset, mode, kw.target_skus]);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const shown = products.filter((p) => !q || `${p.title} ${p.color || ''} ${p.sku}`.toLowerCase().includes(q.toLowerCase()));
  const groups = useMemo(() => {
    const m = new Map();
    for (const p of shown) { const k = p.parent_asin || p.sku; if (!m.has(k)) m.set(k, []); m.get(k).push(p); }
    return [...m.values()];
  }, [shown]);
  const toggle = (skus, on) => setSel((s) => { const n = new Set(s); skus.filter((x) => !bad(x)).forEach((x) => (on ? n.add(x) : n.delete(x))); return n; });
  const ok = shown.filter((p) => !bad(p.sku));
  const allOn = ok.length > 0 && ok.every((p) => sel.has(p.sku));
  const fitCount = fit ? data.products.filter((p) => !fit[p.sku]).length : null;
  const go = async () => {
    setBusy(true);
    try {
      const skus = [...sel];
      const r = mode === 'remove' ? await rpc('api_amz_keyword_remove', { p_id: kw.id, p_skus: skus })
        : mode === 'name' ? await rpc('api_amz_keyword_name', { p_id: kw.id, p_skus: skus })
        : mode === 'hidden' ? await rpc('api_amz_keyword_apply', { p_id: kw.id, p_skus: skus, p_future: false })
        : await rpc('api_amz_keyword_smart', { p_id: kw.id, p_skus: skus });
      onDone(r); onClose();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${PICK[mode][0]}: "${kw.keyword}"`} onClose={onClose} wide>
      <div className="space-y-3">
        {mode !== 'remove' && fit && <div className="text-xs text-glass-secondary">Fits <b>{fitCount}</b> of {data.products.length} products. The others are greyed out with the reason, so the keyword never reaches the wrong shoppers.{kw.group_name ? ` Its own group "${kw.group_name}" is selected.` : ''}</div>}
        <div className="flex flex-wrap gap-2 items-center">
          <div className="relative flex-1 min-w-[180px]">
            <span className="absolute left-3 top-1/2 -translate-y-1/2 text-glass-muted"><Icon name="search" size={15} /></span>
            <input className="glass-input w-full pl-9 pr-3 py-2 text-sm" placeholder="Search products" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search products" />
          </div>
          <button type="button" className="glass-btn-ghost px-3 py-2 text-sm" onClick={() => toggle(shown.map((p) => p.sku), !allOn)}>{allOn ? 'Clear all' : 'Select all'}</button>
        </div>
        {products.length === 0 ? <Empty>{mode === 'remove' ? 'No product has this keyword.' : 'No products.'}</Empty> : (
          <div className="space-y-3 max-h-[52vh] overflow-y-auto pr-1">
            {groups.map((g) => {
              const on = g.every((p) => sel.has(p.sku));
              return (
                <div key={g[0].parent_asin || g[0].sku} className="rounded-2xl" style={{ background: 'rgba(118,118,128,0.06)' }}>
                  {g.length > 1 && (
                    <label className="flex items-center gap-2 px-3 pt-2.5 text-xs font-semibold text-glass-secondary cursor-pointer">
                      <input type="checkbox" checked={on} onChange={() => toggle(g.map((p) => p.sku), !on)} />Whole design · {g.length} colours
                    </label>
                  )}
                  <div className="grid sm:grid-cols-2 gap-1 p-1.5">
                    {g.map((p) => {
                      const st = statusOf(p.sku); const used = p.bytes || 0; const why = bad(p.sku);
                      return (
                        <label key={p.sku} className={`picker-row ${sel.has(p.sku) ? 'is-on' : ''} ${why ? 'is-off' : ''}`} title={why ? `Doesn't fit: ${why}` : undefined}>
                          <input type="checkbox" className="shrink-0" checked={sel.has(p.sku)} disabled={!!why} onChange={() => toggle([p.sku], !sel.has(p.sku))} aria-label={p.title} />
                          {p.image ? <img src={p.image} alt="" className="w-11 h-11 rounded-lg object-cover shrink-0 bg-white" loading="lazy" />
                            : <span className="w-11 h-11 rounded-lg shrink-0 bg-black/5 inline-flex items-center justify-center text-glass-muted"><Icon name="image" size={16} /></span>}
                          <span className="min-w-0 flex-1">
                            <span className="block text-sm font-medium truncate">{p.title || p.sku}</span>
                            <span className="flex items-center gap-1.5 mt-0.5 flex-wrap">
                              {why && <span className="text-[11px] font-medium" style={{ color: '#B25E00' }}>Doesn't fit: {why}</span>}
                              {!why && p.color && <span className="text-[11px] text-glass-muted">{p.color}</span>}
                              {st && STATUS[st] && <Chip style={STATUS[st][1]}>{STATUS[st][0]}</Chip>}
                              <span className="byte-meter" title={`Hidden search words: ${used} of ${data.byte_limit} bytes`}>
                                <span style={{ width: `${Math.min(100, (used / data.byte_limit) * 100)}%`, background: used > data.byte_limit * 0.9 ? '#FF9500' : '#34C759' }} />
                              </span>
                            </span>
                          </span>
                        </label>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
        )}
        <div className="flex flex-wrap items-center justify-between gap-2 pt-1">
          <span className="text-xs text-glass-muted max-w-md">{PICK[mode][2]}</span>
          <button type="button" className="glass-btn px-5 py-2.5 text-sm" disabled={busy || sel.size === 0 || fit === null} onClick={go}>
            {busy ? 'Working…' : `${PICK[mode][1]} ${sel.size} product${sel.size === 1 ? '' : 's'}`}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function PlaceKeyword({ kw, onClose, onDone }) {
  const [v, setV] = useState(kw.placement || 'auto');
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try { await rpc('api_amz_keyword_placement', { p_id: kw.id, p_placement: v }); showToast('Saved. Smart apply uses it from now on.', 'success'); onDone(); onClose(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`Where "${kw.keyword}" goes`} onClose={onClose}>
      <div className="space-y-2" role="radiogroup" aria-label="Where it goes">
        {PLACES.map(([id, label, help]) => (
          <label key={id} className={`picker-row ${v === id ? 'is-on' : ''}`}>
            <input type="radio" name="place" checked={v === id} onChange={() => setV(id)} />
            <span><span className="block text-sm font-semibold">{label}</span><span className="block text-xs text-glass-muted">{help}</span></span>
          </label>))}
        <div className="flex justify-end gap-2 pt-1">
          <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={onClose}>Cancel</button>
          <button type="button" className="glass-btn px-5 py-2 text-sm" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button>
        </div>
      </div>
    </Modal>
  );
}

function EditKeyword({ kw, onClose, onDone }) {
  const [v, setV] = useState(kw.keyword);
  const [busy, setBusy] = useState(false);
  const live = (kw.products || []).filter((p) => ['live', 'pending'].includes(p.status)).length;
  const save = async (e) => {
    e.preventDefault(); setBusy(true);
    try { const r = await rpc('api_amz_keyword_edit', { p_id: kw.id, p_keyword: v }); onDone(r, live); onClose(); }
    catch (er) { showToast(er.message, 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title="Edit keyword" onClose={onClose}>
      <form onSubmit={save} className="space-y-3">
        <input className="glass-input w-full px-3 py-2.5" value={v} onChange={(e) => setV(e.target.value)} maxLength={60} autoFocus aria-label="Keyword" />
        <div className="text-xs text-glass-muted">{bytesOf(v)} bytes. {live > 0 ? `It is on ${live} product${live === 1 ? '' : 's'}: they get the new words instead (as Decisions).` : 'Not on any product yet.'}</div>
        <div className="flex justify-end gap-2">
          <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={onClose}>Cancel</button>
          <button className="glass-btn px-5 py-2 text-sm" disabled={busy || !v.trim()}>{busy ? 'Saving…' : 'Save'}</button>
        </div>
      </form>
    </Modal>
  );
}

function KeywordRow({ k, data, onChanged, goDecisions }) {
  const [open, setOpen] = useState(false);
  const [picker, setPicker] = useState(null);
  const [edit, setEdit] = useState(false);
  const [place, setPlace] = useState(false);
  const [menu, setMenu] = useState(false);
  const [swapping, setSwapping] = useState('');
  const total = data.products.length;
  const on = (k.products || []).filter((p) => ['live', 'pending', 'covered'].includes(p.status)).length;
  const waiting = (k.products || []).filter((p) => p.status === 'pending').length;
  const working = (k.products || []).filter((p) => p.effect === 'working').length;
  const [srcLabel, srcStyle] = SOURCE[k.source] || [k.source, {}];
  const report = (r, verb = 'Added to') => {
    const parts = [];
    if (r?.drafted) parts.push(`${verb} ${r.drafted} product${r.drafted === 1 ? '' : 's'} (waiting in Decisions)`);
    if (r?.changed) parts.push(`Removal for ${r.changed} product${r.changed === 1 ? '' : 's'} waiting in Decisions`);
    if (r?.covered) parts.push(`${r.covered} already findable`);
    if (r?.not_fit) parts.push(`${r.not_fit} skipped (doesn't fit)`);
    if (r?.no_room) parts.push(`${r.no_room} had no room left`);
    if (r?.naming) parts.push(`Claude is drafting names for ${r.naming}${r.mac_online === false ? ' (your Mac is offline: the hourly backup will do it)' : ''}`);
    if (r?.still_in_name) parts.push(`${r.still_in_name} still have it in the name`);
    showToast(parts.join(' · ') || 'Nothing to change', r?.no_room ? 'warning' : 'success');
    onChanged();
  };
  const target = k.target_skus?.length ? k.target_skus.length : total;
  const smart = async () => {
    const where = k.target_skus?.length ? `its own group "${k.group_name}" (${target} products)` : `every product it fits (of ${total})`;
    const ok = await confirmDialog(`Smart apply "${k.keyword}" to ${where}?`, {
      title: `Smart apply "${k.keyword}"?`,
      message: `1. Checks each product truly fits (size, name printing, year, set, cover…).\n2. ${k.placement === 'name' ? 'Hidden search words are left alone.' : `Missing words go into hidden search words (never over ${data.byte_limit} bytes).`}\n3. ${k.main ? 'This is a main keyword, so Claude also drafts names and Item Highlights that carry it.' : 'Not a main keyword, so names stay as they are. Use ⋯ > Suggest better name to ask Claude anyway.'}\nEverything waits in Decisions for you.`,
      confirmText: 'Smart apply' });
    if (!ok) return;
    try { report(await rpc('api_amz_keyword_smart', { p_id: k.id, p_skus: null })); } catch (e) { showToast(e.message, 'error'); }
  };
  const swap = async (p) => {
    if (!(await confirmDialog(`Swap "${p.swap.keyword}" out for "${k.keyword}"?`, { message: 'One Decision: the weaker keyword leaves this product\'s hidden search words and this one goes in.', confirmText: 'Prepare swap' }))) return;
    setSwapping(p.sku);
    try { await rpc('api_amz_keyword_swap', { p_id: k.id, p_sku: p.sku, p_out: p.swap.id }); showToast('Swap waiting in Decisions', 'success'); onChanged(); }
    catch (e) { showToast(e.message, 'error'); } finally { setSwapping(''); }
  };
  const removeAll = async () => {
    if (!(await confirmDialog(`Remove "${k.keyword}" from every product that has it?`, { confirmText: 'Remove', danger: true }))) return;
    try { report(await rpc('api_amz_keyword_remove', { p_id: k.id, p_skus: null })); } catch (e) { showToast(e.message, 'error'); }
  };
  const flag = async (args, msg) => {
    try { await rpc('api_amz_keyword_flag', { p_id: k.id, p_status: null, p_track: null, ...args }); if (msg) showToast(msg, 'success'); onChanged(); }
    catch (e) { showToast(e.message, 'error'); }
  };
  return (
    <div className={`kw-row ${open ? 'is-open' : ''}`}>
      <div className="flex flex-wrap items-start gap-3">
        <button type="button" className="min-w-0 flex-1 text-left" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
          <div className="flex items-center gap-2 flex-wrap">
            <span className="font-semibold text-[15px] text-glass-primary">{k.keyword}</span>
            <Chip style={srcStyle}>{srcLabel}{k.kind && KIND[k.kind] && k.source === 'claude' ? ` · ${KIND[k.kind]}` : ''}</Chip>
            {k.track && <Chip style={BLUE} title={k.watch_auto ? 'Watched automatically because it is applied, so its 14-day result is measured' : 'Searched every morning: your rank and the competitors above you'}><Icon name="search" size={11} />{k.watch_auto ? 'Auto-watched' : 'Watched'}</Chip>}
            {k.group_name && <Chip style={PURPLE} title="This group's own search: other groups don't compete for it">For: {k.group_name}</Chip>}
            {k.main && k.status !== 'rejected' && <Chip style={GREEN} title="Smart apply also asks Claude for names that carry it">Main keyword</Chip>}
            {k.placement && k.placement !== 'auto' && <Chip>{PLACES.find((x) => x[0] === k.placement)?.[1]}</Chip>}
            {k.season_day && <Chip style={AMBER} title="Suggested 3 weeks before the festival, removed 3 days after">Season: {fmtDay(k.season_day)}</Chip>}
            {k.naming && <Chip style={PURPLE}><Icon name="sparkles" size={11} />Claude is drafting names…</Chip>}
            {k.status === 'rejected' && <Chip>Hidden</Chip>}
          </div>
          <div className="flex items-center gap-3 flex-wrap mt-1.5 text-xs text-glass-secondary">
            {k.competitor_count > 0 && k.competitors_total > 0 && <span><b className="text-glass-primary">{k.competitor_count}</b> of {k.competitors_total} top competitors use it</span>}
            {k.checked && <span>You: <b className="text-glass-primary">{rankText(k.rank_today)}</b> <Trend now={k.rank_today} before={k.rank_week_ago} had={k.had_week} /></span>}
            <span title="Products a shopper can already find with every word of this keyword (name, key points, description or hidden search words)">
              Findable in <b className="text-glass-primary">{k.findable ?? 0}</b> of {total}{waiting > 0 ? ` · ${waiting} waiting in Decisions` : ''}{working ? ` · ${working} working ↑` : ''}</span>
            <span className="text-glass-muted">{k.bytes} bytes</span>
          </div>
          {k.why && <div className="text-xs text-glass-muted mt-1">{k.why}</div>}
        </button>
        {data.can_apply && k.status !== 'rejected' && (
          <div className="flex items-center gap-1.5 flex-wrap">
            <button type="button" className="glass-btn px-3.5 py-2 text-sm inline-flex items-center gap-1.5" onClick={smart}><Icon name="sparkles" size={14} />Smart apply</button>
            <button type="button" className="glass-btn-ghost px-3.5 py-2 text-sm" onClick={() => setPicker('smart')}>Selected…</button>
            <div className="relative">
              <button type="button" className="nav-dots" aria-label={`More for ${k.keyword}`} aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((v) => !v)}><Icon name="more" size={18} strokeWidth={2.4} /></button>
              {menu && (
                <>
                  <div className="fixed inset-0 z-40" onClick={() => setMenu(false)} aria-hidden="true" />
                  <div role="menu" className="absolute right-0 top-full mt-1 z-50 min-w-[230px] more-menu p-1.5 animate-glass-in">
                    {[
                      ['Suggest better name…', 'sparkles', () => setPicker('name')],
                      ['Hidden words only…', 'tag', () => setPicker('hidden')],
                      ['Where it goes…', 'pin', () => setPlace(true)],
                      ['Edit keyword', 'form', () => setEdit(true)],
                      on > 0 && ['Remove from selected…', 'trash', () => setPicker('remove')],
                      on > 0 && ['Remove from every product', 'trash', removeAll],
                      [k.track ? 'Stop watching every morning' : 'Watch every morning', 'search', () => flag({ p_track: !k.track }, k.track ? 'No longer watched' : 'Watched from tomorrow morning')],
                      ['Hide this idea', 'ban', () => flag({ p_status: 'rejected' }, 'Hidden')],
                    ].filter(Boolean).map(([label, icon, fn]) => (
                      <button key={label} type="button" role="menuitem" className="menu-item w-full flex items-center gap-3 px-3 min-h-[42px] rounded-xl text-sm text-left"
                        onClick={() => { setMenu(false); fn(); }}><Icon name={icon} size={16} />{label}</button>
                    ))}
                  </div>
                </>
              )}
            </div>
          </div>
        )}
        {data.can_apply && k.status === 'rejected' && <button type="button" className="glass-btn-ghost px-3.5 py-2 text-sm" onClick={() => flag({ p_status: 'candidate' }, 'Shown again')}>Show again</button>}
      </div>
      {open && (
        <div className="mt-3 pt-3 border-t" style={{ borderColor: 'var(--border-subtle)' }}>
          {(k.products || []).length === 0 ? <div className="text-xs text-glass-muted">Not added to any product yet.</div> : (
            <div className="grid sm:grid-cols-2 gap-1.5">
              {k.products.map((p) => {
                const prod = data.products.find((x) => x.sku === p.sku);
                const [label, style] = STATUS[p.status] || [p.status, {}];
                return (
                  <div key={p.sku} className="flex items-center gap-2 text-xs rounded-xl px-2 py-1.5" style={{ background: 'rgba(118,118,128,0.06)' }}>
                    {prod?.image ? <img src={prod.image} alt="" className="w-8 h-8 rounded-md object-cover bg-white shrink-0" loading="lazy" /> : null}
                    <span className="min-w-0 flex-1"><span className="block truncate font-medium">{prod?.title || p.sku}</span>
                      <span className="text-glass-muted">{p.detail || ''}{p.rank_now != null || p.baseline_rank != null ? ` · rank ${rankText(p.baseline_rank)} → ${rankText(p.rank_now)}` : ''}</span></span>
                    <span className="flex flex-col items-end gap-1 shrink-0">
                      <Chip style={style}>{label}</Chip>
                      {p.effect && EFFECT[p.effect] && <Chip style={EFFECT[p.effect][1]}>{EFFECT[p.effect][0]}</Chip>}
                      {p.swap && data.can_apply && <button type="button" className="text-[11px] font-semibold" style={{ color: 'var(--accent)' }} disabled={swapping === p.sku}
                        onClick={() => swap(p)}>{swapping === p.sku ? 'Preparing…' : `Swap out "${p.swap.keyword}"`}</button>}
                    </span>
                  </div>
                );
              })}
            </div>
          )}
          {(k.products || []).some((p) => p.status === 'pending' || p.status === 'removing') && goDecisions &&
            <button type="button" className="mt-2 text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={goDecisions}>Review in Decisions →</button>}
        </div>
      )}
      {picker && <ProductPicker data={data} kw={k} mode={picker} onClose={() => setPicker(null)} onDone={(r) => report(r, 'Added to')} />}
      {place && <PlaceKeyword kw={k} onClose={() => setPlace(false)} onDone={onChanged} />}
      {edit && <EditKeyword kw={k} onClose={() => setEdit(false)} onDone={(r) => { if (r?.drafted || r?.covered || r?.no_room) report(r); else { showToast('Keyword updated', 'success'); onChanged(); } }} />}
    </div>
  );
}

const FILTERS = [['ideas', 'Ideas'], ['mine', 'In use'], ['all', 'All'], ['hidden', 'Hidden']];
export function Keywords({ goDecisions }) {
  const [data, load, err] = useData(useCallback(() => rpc('api_amz_keywords'), []));
  const [kw, setKw] = useState('');
  const [watch, setWatch] = useState(true);
  const [filter, setFilter] = useState('ideas');
  const [q, setQ] = useState('');
  const [asking, setAsking] = useState(false);
  const [group, setGroup] = useState('');
  useEffect(() => { // ideas from Claude arrive in the background
    if (!data?.claude_running) return undefined;
    const t = setInterval(load, 8000);
    return () => clearInterval(t);
  }, [data?.claude_running, load]);
  const add = async (e) => {
    e.preventDefault();
    if (!kw.trim()) return;
    try { const r = await rpc('api_amz_keyword_add', { p_keyword: kw, p_track: watch }); setKw('');
      showToast(watch && !r.tracked ? 'Added. Up to 15 keywords can be watched every morning; this one is not watched.' : 'Keyword added', 'success'); load(); }
    catch (er) { showToast(er.message, 'error'); }
  };
  const niche = async () => {
    if (!(await confirmDialog('Plan a niche for each product group?', { message: 'Claude groups similar products (e.g. aeroplane diaries, photo diaries, sets of 2) and gives each group its own keywords, so your products stop competing with each other. The keywords arrive here as ideas; nothing changes until you apply and approve them.', confirmText: 'Plan niches' }))) return;
    setAsking(true);
    try { await rpc('api_amz_keyword_niche'); showToast('Claude is planning the groups. They appear here in a few minutes.', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setAsking(false); }
  };
  const ideas = async () => {
    setAsking(true);
    try { await rpc('api_amz_keyword_ideas'); showToast('Claude is looking for more keywords. They appear here in a minute or two.', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setAsking(false); }
  };
  if (err) return <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{err}</div>;
  if (!data) return <Empty>Loading…</Empty>;
  const inUse = (k) => (k.products || []).some((p) => ['live', 'pending', 'covered'].includes(p.status));
  const list = data.keywords.filter((k) => {
    if (q && !k.keyword.includes(q.toLowerCase())) return false;
    if (group && k.group_name !== group) return false;
    if (filter === 'hidden') return k.status === 'rejected';
    if (k.status === 'rejected') return false;
    if (filter === 'ideas') return !inUse(k);
    if (filter === 'mine') return inUse(k) || k.track;
    return true;
  });
  const count = (f) => data.keywords.filter((k) => (f === 'hidden' ? k.status === 'rejected' : k.status !== 'rejected' && (f === 'all' || (f === 'ideas' ? !inUse(k) : inUse(k) || k.track)))).length;
  return (
    <div className="space-y-3">
      <div className="glass-card p-4 space-y-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-sm text-glass-secondary max-w-2xl">
              Ideas come from the competitors ranked above you, Claude (spellings, related, gift words and each group's own niche) and festivals.
              <b> Smart apply</b> checks each product fits, adds missing words to hidden search words (limit {data.byte_limit} bytes) and, for main keywords, asks Claude for names that carry them.
              Every change waits in Decisions; applied keywords are watched every morning and after 14 days each product shows if it helped.
            </div>
          </div>
          <div className="flex flex-wrap gap-2 shrink-0">
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm inline-flex items-center gap-2" onClick={niche} disabled={asking || data.niche_running}>
              <Icon name="list" size={15} />{data.niche_running ? 'Planning groups…' : data.groups?.length ? 'Re-plan groups' : 'Plan niches by group'}
            </button>
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm inline-flex items-center gap-2" onClick={ideas} disabled={asking || data.ideas_running}>
              <Icon name="sparkles" size={15} />{data.ideas_running ? 'Claude is thinking…' : 'More ideas from Claude'}
            </button>
          </div>
        </div>
        <form className="flex flex-wrap gap-2 items-center" onSubmit={add}>
          <input className="glass-input flex-1 min-w-[200px] px-3 py-2.5 text-sm" placeholder="Add your own, e.g. diary with name for girls" value={kw} maxLength={60}
            onChange={(e) => setKw(e.target.value)} aria-label="New keyword" />
          <label className="inline-flex items-center gap-2 text-xs text-glass-secondary"><input type="checkbox" checked={watch} onChange={(e) => setWatch(e.target.checked)} />Watch every morning</label>
          <button className="glass-btn px-5 py-2.5 text-sm" disabled={!kw.trim()}>Add</button>
        </form>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <div className="seg-control" style={{ gridTemplateColumns: `repeat(${FILTERS.length}, minmax(0, 1fr))` }} role="tablist" aria-label="Show">
          {FILTERS.map(([id, label]) => (
            <button key={id} type="button" role="tab" aria-selected={filter === id} className={filter === id ? 'is-active' : ''} onClick={() => setFilter(id)}>
              <span className="truncate">{label}</span><span className="text-[11px] opacity-60">{count(id)}</span>
            </button>
          ))}
        </div>
        <div className="relative flex-1 min-w-[160px]">
          <span className="absolute left-3 top-1/2 -translate-y-1/2 text-glass-muted"><Icon name="search" size={15} /></span>
          <input className="glass-input w-full pl-9 pr-3 py-2 text-sm" placeholder="Find a keyword" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Find a keyword" />
        </div>
      </div>
      {data.groups?.length > 0 && (
        <div className="cat-chips" role="group" aria-label="Product group">
          {[['', 'All groups', null], ...data.groups.map((g) => [g.name, g.name, g.skus.length])].map(([id, label, n]) => (
            <button key={id || 'all'} type="button" aria-pressed={group === id} className={`cat-chip ${group === id ? 'is-on' : ''}`} onClick={() => setGroup(id)} title={data.groups.find((g) => g.name === id)?.why || ''}>
              {label}{n != null && <span>{n}</span>}</button>))}
        </div>
      )}
      {list.length === 0 ? (
        <Empty>{filter === 'ideas' ? 'No new ideas right now. They arrive after the morning market check, or ask Claude for more.' : 'Nothing here yet.'}</Empty>
      ) : (
        <div className="space-y-2">{list.map((k) => <KeywordRow key={k.id} k={k} data={data} onChanged={load} goDecisions={goDecisions} />)}</div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Competitors (market watch)
function Delta({ now, before, money, lowerIsBetter }) {
  if (now == null || before == null || Number(now) === Number(before)) return null;
  const diff = Number(now) - Number(before);
  const good = lowerIsBetter ? diff < 0 : diff > 0;
  return <span className="text-[11px] font-semibold ml-1" style={{ color: good ? '#C4261D' : '#1E7B34' }} title="Change since the last check (red = better for them)">
    {diff > 0 ? '▲' : '▼'}{money ? inr(Math.abs(diff)) : Math.abs(diff).toLocaleString('en-IN')}</span>;
}
function CompetitorCard({ c, rank, above, isNew, mine }) {
  return (
    <div className="comp-card">
      <div className="flex gap-3">
        <div className="relative shrink-0">
          {c?.image ? <img src={c.image} alt="" className="w-16 h-16 rounded-xl object-contain bg-white" loading="lazy" />
            : <span className="w-16 h-16 rounded-xl bg-black/5 inline-flex items-center justify-center text-glass-muted"><Icon name="image" size={18} /></span>}
          {rank != null && <span className="rank-badge">#{rank}</span>}
        </div>
        <div className="min-w-0 flex-1">
          <a href={`https://www.amazon.in/dp/${c?.asin}`} target="_blank" rel="noopener noreferrer" className="text-sm font-semibold leading-snug line-clamp-2 hover:underline">{c?.title || c?.asin}</a>
          <div className="flex flex-wrap items-center gap-1.5 mt-1">
            {above != null && <Chip style={above ? RED : BLUE}>{above ? 'Above you' : 'Just below you'}</Chip>}
            {isNew && <Chip style={AMBER}>New today</Chip>}
            {c?.brand && <span className="text-[11px] text-glass-muted">{c.brand}</span>}
          </div>
          <div className="grid grid-cols-3 gap-2 mt-2 text-xs">
            <div><div className="text-glass-muted">Price</div><div className="font-semibold">{c?.price != null ? inr(c.price) : '—'}<Delta now={c?.price} before={c?.price_before} money lowerIsBetter /></div></div>
            <div><div className="text-glass-muted" title="Best-seller rank: lower = sells more">Sales rank</div><div className="font-semibold">{c?.bsr ? `#${Number(c.bsr).toLocaleString('en-IN')}` : '—'}<Delta now={c?.bsr} before={c?.bsr_before} lowerIsBetter /></div></div>
            <div><div className="text-glass-muted">Photos</div><div className="font-semibold">{c?.images ?? '—'}{mine?.photos_avg > 0 && c?.images != null && c.images > mine.photos_avg ? <span className="text-[11px] ml-1" style={{ color: '#C4261D' }}>you {mine.photos_avg}</span> : null}</div></div>
          </div>
          {c?.title_changed && <div className="text-[11px] mt-1" style={{ color: '#B25E00' }}>Changed their title since the last check</div>}
        </div>
      </div>
    </div>
  );
}

export function Competitors({ myAsins }) {
  const [d, load, err] = useData(useCallback(() => rpc('api_amz_market'), []));
  const [busy, setBusy] = useState(false);
  const [asin, setAsin] = useState('');
  const byAsin = useMemo(() => new Map((d?.competitors || []).map((c) => [c.asin, c])), [d]);
  const runNow = async () => {
    setBusy(true);
    try {
      const r = await edge('amazon-sync', { jobs: ['market'] });
      const res = r.results?.[0];
      showToast(res?.status === 'ok' ? `Checked: ${res.detail}` : (res?.detail || r.detail || 'Done'), res?.status === 'ok' ? 'success' : 'error');
      load();
    } catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const addRival = async (e) => {
    e.preventDefault();
    try { await rpc('api_amz_competitor_set', { p_asin: asin, p_my_asin: myAsins?.[0] || null, p_active: true }); setAsin(''); showToast('Added. Its price and rank arrive with the next check.', 'success'); load(); }
    catch (er) { showToast(er.message, 'error'); }
  };
  if (err) return <div className="glass-card p-3 text-sm" style={{ color: '#C4261D' }}>{err}</div>;
  if (!d) return <Empty>Loading…</Empty>;
  const rep = d.report;
  return (
    <div className="space-y-3">
      <div className="glass-card p-4 space-y-2">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h3 className="font-bold">Market this morning</h3>
            <div className="text-xs text-glass-secondary mt-0.5">Every day at 6:50 AM: your rank for each watched keyword, and only the products ranked above you.
              {d.last_run ? ` Last check ${ageText(d.last_run.at)}${d.last_run.status !== 'ok' ? ` (problem: ${d.last_run.detail || 'unknown'})` : ''}.` : ' Not checked yet.'}</div>
          </div>
          {d.can_run && <button type="button" className="glass-btn-ghost px-4 py-2 text-sm inline-flex items-center gap-2 shrink-0" onClick={runNow} disabled={busy}>
            <Icon name="refresh" size={15} />{busy ? 'Checking Amazon…' : 'Check now'}</button>}
        </div>
        {rep && (
          <div className="rounded-2xl p-3 text-sm" style={{ background: 'rgba(175,82,222,0.07)' }}>
            <div className="flex items-center gap-2 text-xs font-semibold mb-1" style={{ color: '#8E3CB8' }}><Icon name="sparkles" size={13} />Claude's morning report · {ageText(rep.at)}</div>
            {rep.status === 'answered' ? <div className="whitespace-pre-line text-glass-primary">{rep.answer}</div>
              : <div className="text-glass-muted">Claude is writing it (needs the Mac Mini online)…</div>}
            {rep.drafts > 0 && <div className="text-xs mt-1 font-semibold" style={{ color: 'var(--accent)' }}>{rep.drafts} suggested change{rep.drafts === 1 ? '' : 's'} waiting in Decisions</div>}
          </div>
        )}
      </div>
      {d.keywords.length === 0 ? (
        <Empty>No market check yet. {d.can_run ? 'Press "Check now", or wait for 6:50 AM.' : 'It runs every morning at 6:50 AM.'} Choose keywords to watch in Keywords.</Empty>
      ) : d.keywords.map((k) => (
        <div key={k.id} className="glass-card p-4 space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="font-semibold">“{k.keyword}”</div>
            <div className="flex items-center gap-2 text-sm">
              <span className="text-glass-muted text-xs">You</span>
              <span className="you-rank" style={k.my_rank === 1 ? { background: '#34C759' } : k.my_rank == null ? { background: '#8E8E93' } : undefined}>{k.my_rank == null ? '20+' : `#${k.my_rank}`}</span>
              <Trend now={k.my_rank} before={k.my_rank_before} had={k.had_before} />
            </div>
          </div>
          {k.watched.length === 0 ? <div className="text-xs text-glass-muted">Nobody to watch for this keyword.</div> : (
            <div className="grid md:grid-cols-2 gap-2">
              {k.watched.map((w) => <CompetitorCard key={w.asin} c={byAsin.get(w.asin) || { asin: w.asin }} rank={w.rank} above={w.above} isNew={w.new} mine={d.mine} />)}
            </div>
          )}
          {k.my_rank == null && <div className="text-xs text-glass-muted">You are not in the top 20 for this search yet, so the top 10 are shown.</div>}
        </div>
      ))}
      <form className="glass-card p-3 flex flex-wrap gap-2 items-center" onSubmit={addRival}>
        <span className="text-sm font-semibold">Watch a specific product</span>
        <input className="glass-input px-3 py-2 text-sm flex-1 min-w-[150px]" placeholder="Its ASIN (B0…)" value={asin} onChange={(e) => setAsin(e.target.value.toUpperCase().trim())} aria-label="Competitor ASIN" />
        <button className="glass-btn px-4 py-2 text-sm" disabled={!/^B0[A-Z0-9]{8}$/.test(asin)}>Watch</button>
        <span className="w-full text-[11px] text-glass-muted">Amazon does not share other sellers' sales, reviews or ad spend with sellers. Shown: price, sales rank, photos and title changes.</span>
      </form>
    </div>
  );
}

// ---------------------------------------------------------------- Settings: Request a Review
export function ReviewRequests() {
  const [d, load] = useData(useCallback(() => rpc('api_amz_reviews', { p_enabled: null }), []));
  if (!d) return null;
  const toggle = async (on) => { try { await rpc('api_amz_reviews', { p_enabled: on }); showToast(on ? 'Review requests on' : 'Review requests off', 'success'); load(); } catch (e) { showToast(e.message, 'error'); } };
  return (
    <div className="glass-card p-4 space-y-2">
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-bold">Ask buyers for a review automatically</h3>
        <label className="inline-flex items-center gap-2 text-sm font-semibold"><input type="checkbox" aria-label="Review requests on" checked={!!d.enabled} onChange={(e) => toggle(e.target.checked)} />{d.enabled ? 'On' : 'Off'}</label>
      </div>
      <div className="text-xs text-glass-secondary">Uses Amazon's own "Request a Review" (the same as the button in Seller Central): one polite Amazon email per order, 5–30 days after delivery. Amazon decides who is eligible; it is fully allowed.</div>
      <div className="flex flex-wrap gap-2 text-sm">
        <Chip style={GREEN}>{d.sent_30d} sent in 30 days</Chip><Chip>{d.sent_total} in total</Chip>{d.waiting > 0 && <Chip>{d.waiting} not eligible yet</Chip>}
      </div>
      {d.last_error && <div className="text-xs" style={{ color: '#C4261D' }}>{d.last_error}</div>}
    </div>
  );
}
