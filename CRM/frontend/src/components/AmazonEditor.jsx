import { useEffect, useMemo, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { chars, utf8Bytes, inr, measureImage, dispatchText, plain, ageText } from '../utils/amazon';
import { ideasFor } from '../utils/amazonIdeas';

// Product gallery + full product editor for CRM > Amazon > My Products.
// Every save goes through api_amz_publish: the same guards as everywhere (₹299 floor, 75-char name, cover rules ...).
// Admin: the save is the approval and the change is sent to Amazon right away (amazon-execute).
// Anyone else: the change waits in Approve Changes.

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function authHeaders() {
  const { data } = await supabase.auth.getSession();
  return { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}` };
}
async function edge(name, body) {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...(await authHeaders()) }, body: JSON.stringify(body) });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}
async function uploadPhoto(file, sku) {
  const fd = new FormData();
  fd.append('file', file); fd.append('sku', sku);
  const res = await fetch(`${SUPABASE_URL}/functions/v1/amazon-upload`, { method: 'POST', headers: await authHeaders(), body: fd });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Upload failed (${res.status})`);
  return out.url;
}

const GREEN = { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' };
const RED = { background: 'rgba(255,59,48,0.12)', color: '#C4261D' };
const AMBER = { background: 'rgba(255,149,0,0.14)', color: '#B25E00' };
const Chip = ({ children, style }) => (
  <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[11px] font-semibold whitespace-nowrap" style={{ background: 'rgba(118,118,128,0.14)', color: '#3C3C43', ...style }}>{children}</span>
);
const coverOf = (l) => (l?.images || [])[0]?.url;
const RESULT = { live: ['Live on Amazon.', 'success'], executing: ['Sent. Amazon is applying it (photos can take a few hours to show).', 'success'],
  failed: ['Amazon said no. See Approve Changes for the reason.', 'error'], stale: ['This product changed on Amazon meanwhile. Nothing sent; try again.', 'error'],
  needs_manual: ['Sent. One part must be set in Seller Central (see Approve Changes).', 'success'], skipped: ['Already being sent.', 'success'] };

// ---------------------------------------------------------------- gallery
export function ProductGallery({ listings, findings, onOpen, q }) {
  const bySku = useMemo(() => {
    const m = {};
    (findings || []).forEach((f) => { if (f.sku) m[f.sku] = (m[f.sku] || 0) + 1; });
    return m;
  }, [findings]);
  const list = (listings || []).filter((r) => !q || `${r.sku} ${r.asin} ${r.title}`.toLowerCase().includes(q.toLowerCase()));
  if (!list.length) return <div className="text-center text-glass-muted py-10 text-sm">No products found.</div>;
  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
      {list.map((r) => {
        const img = coverOf(r);
        return (
          <button key={r.sku} type="button" data-sku={r.sku} onClick={() => onOpen(r.sku)} aria-label={`Edit ${r.title || r.sku}`}
            className="glass-card p-0 overflow-hidden text-left flex flex-col hover:shadow-lg transition-shadow">
            <div className="relative aspect-square bg-white grid place-items-center">
              {img ? <img src={img} alt="" loading="lazy" className="w-full h-full object-contain p-2" /> : <Icon name="image" size={32} />}
              {r.is_parent && <span className="absolute top-2 left-2"><Chip>Group</Chip></span>}
              {bySku[r.sku] > 0 && <span className="absolute top-2 right-2"><Chip style={AMBER}>{bySku[r.sku]} to fix</Chip></span>}
              {(r.images || []).length > 1 && <span className="absolute bottom-2 right-2"><Chip>{r.images.length} photos</Chip></span>}
            </div>
            <div className="p-3 flex-1 flex flex-col gap-1.5">
              <div className="text-[13px] font-semibold text-glass-primary leading-snug line-clamp-2">{r.title || '(no name)'}</div>
              {!r.is_parent && (
                <div className="mt-auto flex flex-wrap items-center gap-1">
                  <span className="text-base font-bold">{inr(r.price)}</span>
                  {r.mrp > r.price && <span className="text-[11px] line-through text-glass-muted">{inr(r.mrp)}</span>}
                </div>
              )}
              {!r.is_parent && (
                <div className="flex flex-wrap gap-1">
                  <Chip style={r.quantity > 0 ? {} : RED}>{r.quantity ?? '?'} in stock</Chip>
                  <Chip style={Number(r.handling_days) === 0 && r.handling_days != null ? GREEN : {}}>Ships {dispatchText(r.handling_days).toLowerCase()}</Chip>
                  {r.has_buybox === false && <Chip style={RED}>Losing Add to Cart</Chip>}
                  {r.status && r.status !== 'Active' && <Chip style={RED}>Not selling</Chip>}
                </div>
              )}
            </div>
          </button>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------- AI ideas
function Ideas({ field, listing, current, onUse, onClose }) {
  const [kw, setKw] = useState([]);
  const [claude, setClaude] = useState([]);
  const [asking, setAsking] = useState(false);
  useEffect(() => { rpc('api_amz_keywords').then((r) => setKw((r || []).filter((k) => k.status !== 'rejected').map((k) => k.keyword))).catch(() => {}); }, []);
  const loadClaude = () => rpc('api_amz_suggestions', { p_sku: listing.sku }).then((r) => setClaude((r || []).filter((x) => x.field === field))).catch(() => {});
  useEffect(() => { loadClaude(); }, [field, listing.sku]); // eslint-disable-line react-hooks/exhaustive-deps
  const [avoid, setAvoid] = useState([]);
  useEffect(() => { rpc('api_amz_style', { p_style: null }).then((st) => setAvoid((st?.avoid_words || []).map((w) => String(w).toLowerCase()))).catch(() => {}); }, []);
  const instant = useMemo(() => ideasFor(field, { ...listing, ...current }, kw)
    .filter((t) => !avoid.some((w) => w && String(t).toLowerCase().includes(w))), [field, listing, current, kw, avoid]);
  const [edits, setEdits] = useState({});
  const waiting = claude.find((c) => c.status === 'waiting');
  const answered = claude.find((c) => c.status === 'answered');
  const claudeIdeas = (answered?.options || []).map((o) => (Array.isArray(o) ? o.join('\n') : String(o)));
  const ask = async () => {
    setAsking(true);
    try { await rpc('api_amz_suggest', { p_sku: listing.sku, p_field: field, p_note: '' }); showToast('Asked Claude. Ideas arrive within about an hour; open this again to see them.', 'success'); loadClaude(); }
    catch (e) { showToast(e.message, 'error'); }
    setAsking(false);
  };
  const card = (id, text, by) => {
    const val = edits[id] ?? text;
    return (
      <div key={id} className="rounded-2xl p-3 space-y-2" style={{ background: 'rgba(0,122,255,0.06)', boxShadow: 'inset 0 0 0 0.5px rgba(0,122,255,0.35)' }}>
        <div className="flex justify-between items-center text-[11px] text-glass-muted"><span>{by}</span>
          {field === 'title' && <span>{chars(val)}/75</span>}{field === 'backend_terms' && <span>{utf8Bytes(val)}/249 bytes</span>}</div>
        <textarea aria-label={`Idea ${id}`} className="glass-input w-full px-3 py-2 text-sm" rows={field === 'title' ? 2 : field === 'bullets' ? 6 : 4}
          value={val} onChange={(e) => setEdits((s) => ({ ...s, [id]: e.target.value }))} />
        <button type="button" className="glass-btn px-3 py-1.5 text-sm" onClick={() => onUse(val)}>Use this</button>
      </div>
    );
  };
  return (
    <div className="glass-card p-4 space-y-3" role="region" aria-label="AI ideas">
      <div className="flex justify-between items-center">
        <h4 className="font-bold inline-flex items-center gap-2"><Icon name="sparkles" size={16} />Ideas{field === 'bullets' ? ' (one key point per line)' : ''}</h4>
        <button type="button" className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={onClose}>Close</button>
      </div>
      <p className="text-xs text-glass-secondary">Pick one, change anything you like, then press Use this. Built only from facts already on this product.</p>
      {instant.length === 0 && <div className="text-sm text-glass-muted">Not enough product details for instant ideas. Ask Claude below.</div>}
      {instant.map((t, i) => card(`i${i}`, t, `Instant idea ${i + 1}`))}
      {claudeIdeas.map((t, i) => card(`c${i}`, t, `Claude's idea ${i + 1}`))}
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className="glass-btn-ghost px-3 py-1.5 text-sm inline-flex items-center gap-1.5" disabled={asking || !!waiting} onClick={ask}>
          <Icon name="sparkles" size={14} />{waiting ? 'Claude is working on it…' : answered ? 'Ask Claude again' : 'Ask Claude for better ideas'}</button>
        {waiting && <span className="text-xs text-glass-muted">Asked {ageText(waiting.created_at)}. Usually ready within an hour.</span>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- small inputs
function Field({ label, hint, count, max, unit = 'characters', children, ai }) {
  const over = max != null && count > max;
  return (
    <div className="space-y-1">
      <div className="flex justify-between items-end gap-2">
        <span className="text-sm font-semibold text-glass-primary">{label}</span>
        <span className="flex items-center gap-2">
          {max != null && <span className="text-[11px]" style={{ color: over ? '#C4261D' : 'var(--text-muted, #8E8E93)' }}>{count}/{max} {unit}</span>}
          {ai && <button type="button" onClick={ai} className="text-xs font-semibold inline-flex items-center gap-1 px-2 py-1 rounded-full" style={{ background: 'rgba(175,82,222,0.12)', color: '#8E3BBF' }}><Icon name="sparkles" size={12} />Generate with AI</button>}
        </span>
      </div>
      {children}
      {hint && <div className="text-[11px] text-glass-muted">{hint}</div>}
    </div>
  );
}
function Checks({ g }) {
  if (!g) return null;
  const items = [...(g.blockers || []).map((i) => ['Must fix', RED, i]), ...(g.confirms || []).map((i) => ['Double-check', { background: 'rgba(0,122,255,0.12)', color: '#0062CC' }, i]),
    ...(g.warnings || []).map((i) => ['Heads up', AMBER, i])];
  if (!items.length) return <div className="text-xs" style={{ color: '#1E7B34' }}>All Amazon rules pass.</div>;
  return <ul className="space-y-1">{items.map(([w, st, i], n) => <li key={n} className="text-xs flex gap-2 items-start"><Chip style={st}>{w}</Chip><span className="text-glass-secondary">{i.message}</span></li>)}</ul>;
}

// Simple product details (one plain value each) that can be edited here.
const LOCKED = /^(item_name|bullet_point|product_description|generic_keyword|purchasable_offer|list_price|fulfillment_availability|main_product_image_locator|other_product_image_locator_\d|swatch_product_image_locator|merchant_suggested_asin|condition_type|skip_offer|brand|externally_assigned_product_identifier|supplier_declared_.*|manufacturer|country_of_origin|item_package_quantity|maximum_retail_price|batteries_required|recommended_browse_nodes|external_product_information|.*_contact_information|merchant_shipping_group)$/;
const NICE = { color: 'Colour', paper_size: 'Paper size', size: 'Size', page_count: 'Number of pages', ruling_type: 'Ruling (lines)', pattern: 'Pattern',
  style: 'Style', theme: 'Theme', item_type_name: 'Product type name', model_number: 'Model number', part_number: 'Part number',
  number_of_items: 'Items in the pack', sheet_count: 'Number of sheets', specific_uses_for_product: 'Used for', team_name: 'Team / brand line',
  binding: 'Binding', paper_dimensions: 'Paper dimensions', unit_count: 'Unit count', material: 'Material', closure: 'Closure' };
export function simpleDetails(attributes) {
  return Object.entries(attributes || {})
    .filter(([k, v]) => !LOCKED.test(k) && Array.isArray(v) && v.length === 1 && v[0] && ['string', 'number', 'boolean'].includes(typeof v[0].value))
    .map(([k, v]) => ({ key: k, label: NICE[k] || k.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()), value: v[0].value, el: v[0] }))
    .sort((a, b) => (NICE[a.key] ? 0 : 1) - (NICE[b.key] ? 0 : 1) || a.label.localeCompare(b.label));
}

// ---------------------------------------------------------------- editor
export function ProductEditor({ listing, access, onClose, onSaved }) {
  const l = listing;
  const [tab, setTab] = useState('photos');
  const [busy, setBusy] = useState(false);
  const isAdmin = !!access?.is_admin;
  const saveWord = isAdmin ? 'Save & publish' : 'Send for approval';

  // text
  const [title, setTitle] = useState(l.title || '');
  const [bullets, setBullets] = useState(l.bullets?.length ? l.bullets : ['', '', '', '', '']);
  const [description, setDescription] = useState(l.description || '');
  const [backend, setBackend] = useState(l.backend_terms || '');
  const [ideas, setIdeas] = useState('');
  // price & stock
  const [price, setPrice] = useState(l.price ?? '');
  const [mrp, setMrp] = useState(l.mrp ?? '');
  const [qty, setQty] = useState(l.quantity ?? '');
  const [days, setDays] = useState(l.handling_days ?? '');
  // photos
  const [photos, setPhotos] = useState((l.images || []).map((i) => ({ url: i.url })));
  const [coverNoText, setCoverNoText] = useState(false);
  const fileRef = useRef(null);
  // details
  const details = useMemo(() => simpleDetails(l.attributes), [l.attributes]);
  const [vals, setVals] = useState(() => Object.fromEntries(details.map((d) => [d.key, d.value])));

  const textAfter = () => {
    const a = {};
    if (title.trim() !== (l.title || '')) a.title = title.trim();
    const b = bullets.map((x) => x.trim()).filter(Boolean);
    if (JSON.stringify(b) !== JSON.stringify(l.bullets || [])) a.bullets = b;
    if (description.trim() !== (l.description || '')) a.description = description.trim();
    if (backend.trim() !== (l.backend_terms || '')) a.backend_terms = backend.trim();
    return a;
  };
  const priceAfter = () => {
    const a = {};
    if (price !== '' && Number(price) !== Number(l.price)) a.price = Number(price);
    if (mrp !== '' && Number(mrp) !== Number(l.mrp)) a.mrp = Number(mrp);
    if (qty !== '' && Number(qty) !== Number(l.quantity)) a.quantity = Number(qty);
    if (days !== '' && (l.handling_days == null || Number(days) !== Number(l.handling_days))) a.handling_days = Number(days);
    return a;
  };
  const photosAfter = () => {
    const now = photos.map((p) => p.url);
    if (JSON.stringify(now) === JSON.stringify((l.images || []).map((i) => i.url))) return {};
    const out = photos.map((p, i) => (i === 0 ? { ...p, ...(p.url !== coverOf(l) && coverNoText ? { has_text: false } : {}) } : { url: p.url }));
    return { images: out };
  };
  const detailsAfter = () => {
    const changed = {};
    details.forEach((d) => {
      const nv = vals[d.key];
      if (String(nv ?? '') !== String(d.value ?? '')) {
        const typed = typeof d.value === 'number' ? Number(nv) : typeof d.value === 'boolean' ? nv === true || nv === 'true' : String(nv).trim();
        changed[d.key] = [{ ...d.el, value: typed }];
      }
    });
    return Object.keys(changed).length ? { attributes: changed } : {};
  };
  const current = { text: textAfter, price: priceAfter, photos: photosAfter, details: detailsAfter }[tab];

  // live check of the tab being edited
  const [guard, setGuard] = useState(null);
  const after = current();
  const afterKey = JSON.stringify(after);
  useEffect(() => {
    if (afterKey === '{}') { setGuard(null); return undefined; }
    const t = setTimeout(() => {
      rpc('api_amz_check', { p_kind: tab === 'price' ? 'price' : 'listing', p_sku: l.sku, p_after: JSON.parse(afterKey) }).then(setGuard).catch(() => {});
    }, 400);
    return () => clearTimeout(t);
  }, [afterKey, tab, l.sku]);

  const save = async (second = false) => {
    const a = current();
    if (!Object.keys(a).length) { showToast('Nothing changed yet.', 'info'); return; }
    setBusy(true);
    try {
      const kind = tab === 'price' ? 'price' : 'listing';
      const summary = { text: 'Edited name & text', price: 'Price & stock', photos: 'Photos', details: 'Product details' }[tab];
      const r = await rpc('api_amz_publish', { p_kind: kind, p_sku: l.sku, p_after: a, p_summary: summary, p_second_confirm: second });
      if (r.status === 'blocked') showToast(`Not saved: ${(r.guard_result?.blockers || []).map((b) => b.message).join(' ')}`, 'error');
      else if (r.status === 'confirm') {
        const msg = (r.guard_result?.confirms || []).map((c) => c.message).join('\n');
        setBusy(false);
        if (await confirmDialog(msg, { title: 'Please check', confirmText: 'Yes, publish', danger: true })) await save(true);
        return;
      } else if (r.status === 'pending') { showToast('Sent for approval. Admin approves it in Approve Changes.', 'success'); onSaved?.(); }
      else if (r.status === 'stale') showToast('This product changed on Amazon meanwhile. Reopen it and try again.', 'error');
      else if (r.status === 'approved') {
        showToast('Publishing to Amazon…', 'info');
        const ex = await edge('amazon-execute', { id: r.id }).catch((e) => ({ status: 'error', detail: e.message }));
        const [m, t] = RESULT[ex.status] || [ex.detail || 'Sent. Check Approve Changes.', ex.status === 'error' ? 'error' : 'success'];
        showToast(m, t);
        onSaved?.();
      }
    } catch (e) { showToast(e.message, 'error'); }
    setBusy(false);
  };

  const addFiles = async (files) => {
    const list = [...files].slice(0, Math.max(0, 9 - photos.length));
    if (!list.length) { showToast('Amazon allows 9 photos. Remove one first.', 'error'); return; }
    setBusy(true);
    for (const f of list) {
      try {
        if (!/^image\/(jpeg|png)$/.test(f.type)) throw new Error(`${f.name}: only JPG or PNG`);
        const m = await measureImage(f);
        if (Math.max(m.width, m.height) < 1000) showToast(`${f.name} is ${m.width}x${m.height}px. Amazon wants at least 1000px for zoom.`, 'info');
        const url = await uploadPhoto(f, l.sku);
        setPhotos((p) => [...p, { url, ...m }]);
      } catch (e) { showToast(e.message, 'error'); }
    }
    setBusy(false);
  };
  const move = (i, d) => setPhotos((p) => { const n = [...p]; const j = i + d; if (j < 0 || j >= n.length) return p; [n[i], n[j]] = [n[j], n[i]]; return n; });
  const makeCover = (i) => setPhotos((p) => [p[i], ...p.filter((_, k) => k !== i)]);
  const remove = (i) => setPhotos((p) => p.filter((_, k) => k !== i));
  const coverChanged = photos[0]?.url !== coverOf(l);

  const TABS = [['photos', 'Photos', 'image'], ['text', 'Name & text', 'form'], ['price', 'Price & stock', 'tag'], ['details', 'Details', 'list']];
  const changedCount = Object.keys(after).length;

  return (
    <div className="space-y-4">
      <button type="button" onClick={onClose} className="text-sm font-semibold inline-flex items-center gap-1" style={{ color: 'var(--accent)' }}><Icon name="chevronLeft" size={16} />All products</button>
      <div className="glass-card p-4 flex gap-4 items-start">
        <div className="w-24 h-24 sm:w-32 sm:h-32 rounded-2xl bg-white grid place-items-center shrink-0 overflow-hidden">{coverOf(l) ? <img src={coverOf(l)} alt="" className="w-full h-full object-contain" /> : <Icon name="image" size={28} />}</div>
        <div className="min-w-0 space-y-1.5">
          <h3 className="font-bold text-glass-primary leading-snug">{l.title}</h3>
          <div className="flex flex-wrap gap-1.5">
            {!l.is_parent && <Chip>{inr(l.price)}</Chip>}
            {!l.is_parent && <Chip>{l.quantity ?? '?'} in stock</Chip>}
            <Chip style={l.status === 'Active' ? GREEN : RED}>{l.status === 'Active' ? 'Selling' : 'Not selling'}</Chip>
            {l.has_buybox === true && <Chip style={GREEN}>You win Add to Cart</Chip>}
            {l.has_buybox === false && <Chip style={RED}>Another seller wins Add to Cart</Chip>}
          </div>
          <div className="text-[11px] text-glass-muted">{l.asin} · {l.sku} · <a href={`https://www.amazon.in/dp/${l.asin}`} target="_blank" rel="noreferrer" style={{ color: 'var(--accent)' }}>See on Amazon</a></div>
          {(l.issues || []).length > 0 && <div className="text-xs" style={{ color: '#C4261D' }}>Amazon says: {l.issues.map((i) => i.message).join(' | ').slice(0, 300)}</div>}
        </div>
      </div>

      <div role="tablist" aria-label="Edit" className="glass-card p-1 grid grid-cols-4 gap-1">
        {TABS.map(([id, label, icon]) => (
          <button key={id} type="button" role="tab" aria-selected={tab === id} onClick={() => { setTab(id); setIdeas(''); }}
            className="flex flex-col sm:flex-row items-center justify-center gap-1 rounded-xl py-2 text-[11px] sm:text-sm"
            style={tab === id ? { background: '#007AFF', color: '#fff', fontWeight: 600 } : undefined}><Icon name={icon} size={16} />{label}</button>
        ))}
      </div>

      {tab === 'photos' && (
        <div className="glass-card p-4 space-y-3">
          <p className="text-xs text-glass-secondary">The first photo is the cover customers see in search. Use the arrows to reorder. Up to 9 photos.</p>
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
            {photos.map((p, i) => (
              <div key={`${p.url}${i}`} className="rounded-2xl overflow-hidden bg-white relative" style={{ boxShadow: i === 0 ? '0 0 0 2px #007AFF' : 'inset 0 0 0 0.5px rgba(0,0,0,0.15)' }}>
                <img src={p.url} alt={`Photo ${i + 1}`} className="w-full aspect-square object-contain" />
                {i === 0 && <span className="absolute top-2 left-2"><Chip style={{ background: '#007AFF', color: '#fff' }}>Cover</Chip></span>}
                <div className="flex justify-between p-1.5 gap-1" style={{ background: 'rgba(118,118,128,0.08)' }}>
                  <button type="button" aria-label={`Move photo ${i + 1} left`} className="glass-btn-ghost px-2 py-1 text-xs" disabled={i === 0} onClick={() => move(i, -1)}><Icon name="chevronLeft" size={14} /></button>
                  {i > 0 && <button type="button" aria-label={`Make photo ${i + 1} the cover`} className="glass-btn-ghost px-2 py-1 text-[11px]" onClick={() => makeCover(i)}>Cover</button>}
                  <button type="button" aria-label={`Remove photo ${i + 1}`} className="glass-btn-ghost px-2 py-1 text-xs" style={{ color: '#C4261D' }} disabled={photos.length === 1} onClick={() => remove(i)}><Icon name="trash" size={14} /></button>
                  <button type="button" aria-label={`Move photo ${i + 1} right`} className="glass-btn-ghost px-2 py-1 text-xs" disabled={i === photos.length - 1} onClick={() => move(i, 1)}><Icon name="chevronRight" size={14} /></button>
                </div>
              </div>
            ))}
            {photos.length < 9 && (
              <button type="button" onClick={() => fileRef.current?.click()} disabled={busy} className="rounded-2xl aspect-square grid place-items-center text-sm font-semibold"
                style={{ border: '2px dashed rgba(0,122,255,0.45)', color: '#007AFF' }}>
                <span className="flex flex-col items-center gap-1"><Icon name="plus" size={22} />{busy ? 'Uploading…' : 'Add photos'}</span>
              </button>
            )}
          </div>
          <input ref={fileRef} type="file" accept="image/jpeg,image/png" multiple hidden aria-label="Upload photos" onChange={(e) => { addFiles(e.target.files); e.target.value = ''; }} />
          {coverChanged && (
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" checked={coverNoText} onChange={(e) => setCoverNoText(e.target.checked)} className="mt-1" />
              <span>The new cover has a <b>pure white background</b> and <b>no text, logo or watermark</b> (Amazon's cover rule).</span>
            </label>
          )}
        </div>
      )}

      {tab === 'text' && (
        <div className="space-y-3">
          <div className="glass-card p-4 space-y-4">
            <Field label="Product name" count={chars(title)} max={75} ai={() => setIdeas('title')}>
              <textarea aria-label="Product name" className="glass-input w-full px-3 py-2 text-sm" rows={2} value={title} onChange={(e) => setTitle(e.target.value)} />
            </Field>
            {ideas === 'title' && <Ideas field="title" listing={l} current={{ title }} onUse={(t) => { setTitle(t); setIdeas(''); }} onClose={() => setIdeas('')} />}
            <Field label="Key points (shown as bullet points)" ai={() => setIdeas('bullets')}>
              <div className="space-y-2">
                {bullets.map((b, i) => (
                  <div key={i} className="flex gap-2 items-start">
                    <textarea aria-label={`Key point ${i + 1}`} className="glass-input flex-1 px-3 py-2 text-sm" rows={2} value={b} onChange={(e) => setBullets((s) => s.map((x, k) => (k === i ? e.target.value : x)))} />
                    <button type="button" aria-label={`Remove key point ${i + 1}`} className="glass-btn-ghost px-2 py-2" onClick={() => setBullets((s) => s.filter((_, k) => k !== i))}><Icon name="close" size={14} /></button>
                  </div>
                ))}
                {bullets.length < 10 && <button type="button" className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setBullets((s) => [...s, ''])}>+ Add a key point</button>}
              </div>
            </Field>
            {ideas === 'bullets' && <Ideas field="bullets" listing={l} current={{}} onUse={(t) => { setBullets(t.split('\n').map((x) => x.trim()).filter(Boolean)); setIdeas(''); }} onClose={() => setIdeas('')} />}
            <Field label="Description" count={chars(description)} max={2000} ai={() => setIdeas('description')}>
              <textarea aria-label="Description" className="glass-input w-full px-3 py-2 text-sm" rows={6} value={description} onChange={(e) => setDescription(e.target.value)} />
            </Field>
            {ideas === 'description' && <Ideas field="description" listing={l} current={{}} onUse={(t) => { setDescription(t); setIdeas(''); }} onClose={() => setIdeas('')} />}
            <Field label="Hidden search words" hint="Buyers never see these. Words that are not in the name, separated by spaces." count={utf8Bytes(backend)} max={249} unit="bytes" ai={() => setIdeas('backend_terms')}>
              <textarea aria-label="Hidden search words" className="glass-input w-full px-3 py-2 text-sm" rows={3} value={backend} onChange={(e) => setBackend(e.target.value)} />
            </Field>
            {ideas === 'backend_terms' && <Ideas field="backend_terms" listing={l} current={{ title }} onUse={(t) => { setBackend(t); setIdeas(''); }} onClose={() => setIdeas('')} />}
          </div>
        </div>
      )}

      {tab === 'price' && (
        l.is_parent ? <div className="glass-card p-4 text-sm text-glass-secondary">This is a group listing. Open each size/colour to change its price and stock.</div> : (
          <div className="glass-card p-4 grid sm:grid-cols-2 gap-4">
            <Field label="Price (₹)" hint={`Never below ₹299.${l.buybox_price ? ` The seller winning Add to Cart asks ${inr(l.buybox_price)}.` : ''}`}>
              <input aria-label="Price" type="number" min="299" step="1" className="glass-input w-full px-3 py-2" value={price} onChange={(e) => setPrice(e.target.value)} />
            </Field>
            <Field label="MRP (₹)" hint="Printed price. Must be the same or higher than your price.">
              <input aria-label="MRP" type="number" min="0" step="1" className="glass-input w-full px-3 py-2" value={mrp} onChange={(e) => setMrp(e.target.value)} />
            </Field>
            <Field label="Stock" hint="How many you can ship. 0 stops sales.">
              <input aria-label="Stock" type="number" min="0" step="1" className="glass-input w-full px-3 py-2" value={qty} onChange={(e) => setQty(e.target.value)} />
            </Field>
            <Field label="Dispatch time" hint="Same day: hand over orders the day they come (pickup booked before 12 noon).">
              <select aria-label="Dispatch time" className="glass-input w-full px-3 py-2" value={days} onChange={(e) => setDays(e.target.value)}>
                {days === '' && <option value="">Not known yet</option>}
                <option value="0">Same day</option><option value="1">Next day</option><option value="2">2 days</option><option value="3">3 days</option>
              </select>
            </Field>
          </div>
        )
      )}

      {tab === 'details' && (
        <div className="glass-card p-4 space-y-3">
          <p className="text-xs text-glass-secondary">Facts Amazon shows in "Product details" and uses in filters. Keep them true to the product.</p>
          {details.length === 0 ? <div className="text-sm text-glass-muted">No editable details yet. They appear after the next update from Amazon.</div> : (
            <div className="grid sm:grid-cols-2 gap-3">
              {details.map((d) => (
                <Field key={d.key} label={d.label}>
                  {typeof d.value === 'boolean' ? (
                    <select aria-label={d.label} className="glass-input w-full px-3 py-2 text-sm" value={String(vals[d.key])} onChange={(e) => setVals((s) => ({ ...s, [d.key]: e.target.value === 'true' }))}>
                      <option value="true">Yes</option><option value="false">No</option></select>
                  ) : (
                    <input aria-label={d.label} type={typeof d.value === 'number' ? 'number' : 'text'} className="glass-input w-full px-3 py-2 text-sm"
                      value={vals[d.key] ?? ''} onChange={(e) => setVals((s) => ({ ...s, [d.key]: e.target.value }))} />
                  )}
                </Field>
              ))}
            </div>
          )}
        </div>
      )}

      <div className="h-2" />
      <div className="glass-card p-4 space-y-3 sticky bottom-2 z-10" style={{ background: 'var(--surface-elevated, #fff)', backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)' }}>
        {changedCount > 0 ? <div className="max-h-28 overflow-y-auto"><Checks g={guard} /></div> : <div className="text-xs text-glass-muted">No changes yet.</div>}
        <div className="flex flex-wrap gap-2 items-center">
          <button type="button" className="glass-btn px-5 py-2 text-sm" disabled={busy || !changedCount || guard?.ok === false} onClick={() => save(false)}>{busy ? 'Working…' : saveWord}</button>
          <span className="text-[11px] text-glass-muted">{isAdmin ? 'Goes live on Amazon in about a minute. You can undo it in Approve Changes.' : 'Admin approves it before it goes live.'}</span>
        </div>
      </div>
    </div>
  );
}
