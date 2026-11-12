import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import { confirmDialog } from './ui/dialogs';
import Icon from './icons';
import { Modal } from './AmazonDecisions';
import { Designer } from './AmazonDesigner';

// CRM > Amazon > Studio (part 1: photos).
// Your real diary photos -> the Mac checks them -> cut-out (2 options) -> main photo on pure white / clean colour swatch
// -> Send to Decisions. The diary itself is never redrawn; nothing reaches Amazon until it is approved in Decisions.

const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
};
async function studio(body, isForm = false) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/amazon-studio`, {
    method: 'POST',
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${data.session?.access_token || ''}`, ...(isForm ? {} : { 'Content-Type': 'application/json' }) },
    body: isForm ? body : JSON.stringify(body) });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.detail || `Request failed (${res.status})`);
  return out;
}

const SLOTS = [
  { id: '1', label: 'Main photo', hint: 'Pure white background, no text. The Studio main photo is made for this.' },
  ...[2, 3, 4, 5, 6, 7, 8, 9].map((n) => ({ id: String(n), label: `Photo ${n}`, hint: 'Lifestyle, features with pointers, size, inside pages, how to add your name.' })),
  { id: 'swatch', label: 'Colour swatch', hint: 'A small square of the real cover texture. No text, no logo.' },
];
const KIND = { upload: 'Your photo', cutout: 'Cut-out', main: 'Main photo', swatch: 'Swatch', design: 'Design' };
const LEVEL = { ok: ['✓', '#1E7B34'], warn: ['!', '#B25E00'], bad: ['✕', '#C4261D'] };
const fits = (slot, a) => (slot === '1' ? a.kind === 'main' : slot === 'swatch' ? a.kind === 'swatch' : ['main', 'upload', 'design'].includes(a.kind));
const scoreStyle = (s) => (s == null ? {} : s >= 85 ? { background: 'rgba(52,199,89,0.16)', color: '#1E7B34' } : s >= 70 ? { background: 'rgba(255,149,0,0.16)', color: '#B25E00' } : { background: 'rgba(255,59,48,0.14)', color: '#C4261D' });

function Score({ s }) {
  if (s == null) return null;
  return <span className="studio-score" style={scoreStyle(s)} title="Photo score out of 100">{s}</span>;
}
function Checks({ list }) {
  if (!list?.length) return null;
  return (
    <ul className="space-y-0.5 text-[11px]">
      {list.map((c) => { const [m, col] = LEVEL[c.level] || LEVEL.ok; return <li key={c.code} className="flex gap-1.5"><span style={{ color: col }} className="font-bold w-3">{m}</span><span className="text-glass-secondary">{c.message}</span></li>; })}
    </ul>
  );
}

// Drag a square on the photo to choose the swatch area (plain cover texture, away from text).
function SwatchPicker({ asset, url, onClose, onPick }) {
  const box = useRef(null);
  const [r, setR] = useState(null);
  const start = useRef(null);
  const pos = (e) => { const b = box.current.getBoundingClientRect(); return { x: Math.min(1, Math.max(0, (e.clientX - b.left) / b.width)), y: Math.min(1, Math.max(0, (e.clientY - b.top) / b.height)), w: b.width, h: b.height }; };
  const down = (e) => { e.preventDefault(); box.current.setPointerCapture(e.pointerId); start.current = pos(e); setR(null); };
  const move = (e) => {
    if (!start.current) return;
    const p = pos(e); const s = start.current;
    const side = Math.min(Math.abs(p.x - s.x) * p.w, Math.abs(p.y - s.y) * p.h);    // keep it square on screen
    setR({ x: p.x < s.x ? s.x - side / p.w : s.x, y: p.y < s.y ? s.y - side / p.h : s.y, w: side / p.w, h: side / p.h });
  };
  const up = () => { start.current = null; };
  return (
    <Modal title="Choose the swatch area" onClose={onClose} wide>
      <div className="space-y-3">
        <div className="text-xs text-glass-secondary">Drag a square over plain cover texture: no text, no year, no logo, no stitching edge.</div>
        <div ref={box} className="relative select-none touch-none mx-auto max-w-md" onPointerDown={down} onPointerMove={move} onPointerUp={up}>
          <img src={url} alt="" className="w-full rounded-xl" draggable={false} />
          {r && <div className="absolute border-2 border-white rounded-sm" style={{ left: `${r.x * 100}%`, top: `${r.y * 100}%`, width: `${r.w * 100}%`, height: `${r.h * 100}%`, boxShadow: '0 0 0 9999px rgba(0,0,0,.45)' }} />}
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={onClose}>Cancel</button>
          <button type="button" className="glass-btn px-5 py-2 text-sm" disabled={!r || r.w < 0.03} onClick={() => onPick(asset, r)}>Make swatch</button>
        </div>
      </div>
    </Modal>
  );
}

function AssetCard({ a, url, slot, canSend, busy, onJob, onSend, onDelete, onSwatch, onDesign }) {
  const pending = a.kind === 'upload' && a.score == null;
  return (
    <div className={`studio-card ${a.status === 'sent' ? 'is-sent' : ''}`} data-asset={a.kind}>
      <div className="studio-thumb">
        {url ? <img src={url} alt={KIND[a.kind]} loading="lazy" /> : <span className="text-glass-muted"><Icon name="image" size={20} /></span>}
        <span className="studio-kind">{KIND[a.kind]}{a.meta?.mode ? ` · ${a.meta.mode === 'fine' ? 'fine edges' : 'soft edges'}` : ''}</span>
        <Score s={a.score} />
      </div>
      <div className="p-2.5 space-y-2">
        {pending ? <div className="text-[11px] text-glass-muted">Checking on your Mac…</div> : <Checks list={a.checks} />}
        <div className="flex flex-wrap gap-1.5">
          {a.kind === 'upload' && !pending && slot !== 'swatch' && <button type="button" className="glass-btn-ghost px-2.5 py-1.5 text-xs" disabled={busy} onClick={() => onJob('cutout', a)}>Make cut-out</button>}
          {['upload', 'cutout'].includes(a.kind) && slot === 'swatch' && <button type="button" className="glass-btn-ghost px-2.5 py-1.5 text-xs" disabled={busy || !url} onClick={() => onSwatch(a)}>Choose swatch area</button>}
          {a.kind === 'cutout' && slot !== 'swatch' && <button type="button" className="glass-btn-ghost px-2.5 py-1.5 text-xs" disabled={busy} onClick={() => onJob('main', a)}>Make main photo</button>}
          {!['1', 'swatch'].includes(slot) && !pending && a.status !== 'deleted' && onDesign && (
            <button type="button" className="glass-btn-ghost px-2.5 py-1.5 text-xs" disabled={busy} onClick={() => onDesign(a)}>{a.kind === 'design' ? 'Edit text & pointers' : 'Add text & pointers'}</button>)}
          {canSend && fits(slot, a) && a.status === 'ready' && !pending && (
            <button type="button" className="glass-btn px-2.5 py-1.5 text-xs" disabled={busy || (a.score != null && a.score < 70)} title={a.score != null && a.score < 70 ? 'Score under 70: fix the issues first' : ''}
              onClick={() => onSend(a)}>Send to Decisions</button>)}
          {a.status === 'sent' && <span className="text-[11px] font-semibold" style={{ color: '#1E7B34' }}>In Decisions</span>}
          {a.status === 'ready' && <button type="button" className="text-[11px] text-glass-muted ml-auto" onClick={() => onDelete(a)} aria-label="Delete photo">Delete</button>}
        </div>
      </div>
    </div>
  );
}

export function Studio({ access, goDecisions }) {
  const [sku, setSku] = useState(() => { try { return localStorage.getItem('studio.sku') || ''; } catch { return ''; } });
  const [slot, setSlot] = useState('1');
  const [d, setD] = useState(null);
  const [urls, setUrls] = useState({});
  const [busy, setBusy] = useState(false);
  const [picker, setPicker] = useState(null);
  const [designer, setDesigner] = useState(null);
  const fileRef = useRef(null);
  const load = useCallback(async () => {
    try {
      const r = await rpc('api_amz_studio', { p_sku: sku || null });
      if (!sku && r.products?.length) { setSku(r.products[0].sku); return; }
      setD(r);
      const need = (r.assets || []).map((a) => a.id).filter((id) => !urls[id]);
      if (need.length) { const u = await studio({ action: 'urls', ids: need }).catch(() => ({})); setUrls((x) => ({ ...x, ...u })); }
    } catch (e) { showToast(e.message, 'error'); }
  }, [sku]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setD(null); load(); try { if (sku) localStorage.setItem('studio.sku', sku); } catch { /* private mode */ } }, [sku]); // eslint-disable-line react-hooks/exhaustive-deps
  const running = (d?.jobs || []).some((j) => ['waiting', 'working'].includes(j.status));
  useEffect(() => { if (!running) return undefined; const t = setInterval(load, 4000); return () => clearInterval(t); }, [running, load]);

  const upload = async (files) => {
    if (!files?.length) return;
    setBusy(true);
    let ok = 0;
    for (const f of [...files].slice(0, 10)) {
      const fd = new FormData(); fd.append('file', f); fd.append('sku', sku);
      try { await studio(fd, true); ok++; } catch (e) { showToast(`${f.name}: ${e.message}`, 'error'); }
    }
    setBusy(false);
    if (ok) showToast(`${ok} photo${ok > 1 ? 's' : ''} uploaded. Your Mac checks ${ok > 1 ? 'them' : 'it'} now.`, 'success');
    if (fileRef.current) fileRef.current.value = '';
    load();
  };
  const job = async (kind, a, params = {}) => {
    setBusy(true);
    try { await rpc('api_amz_studio_job', { p_sku: sku, p_kind: kind, p_assets: [a.id], p_params: params });
      showToast(kind === 'cutout' ? 'Your Mac is cutting it out (two options, about a minute).' : kind === 'main' ? 'Your Mac is making the main photo.' : 'Your Mac is making the swatch.', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const send = async (a) => {
    const label = SLOTS.find((s) => s.id === slot)?.label;
    if (!(await confirmDialog(`Send this as "${label}" to Decisions?`, { message: 'It waits in Decisions > Photos. Nothing changes on Amazon until you approve it there, and it can be undone.', confirmText: 'Send to Decisions' }))) return;
    setBusy(true);
    try { await studio({ action: 'send', asset: a.id, slot }); showToast('Waiting in Decisions > Photos', 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const openDesigner = (a) => {
    if (a.kind === 'design') {
      const parent = (d?.assets || []).find((x) => x.id === a.parent);
      setDesigner({ base: { ...(parent || { id: null, kind: 'main' }), layers: a.layers || [] }, baseUrl: parent ? urls[parent.id] : null });
    } else setDesigner({ base: { ...a, layers: [] }, baseUrl: urls[a.id] });
  };
  const uploadDesign = async ({ blob, layers, checks, parent }) => {
    const fd = new FormData();
    fd.append('file', new File([blob], 'design.jpg', { type: 'image/jpeg' })); fd.append('sku', sku); fd.append('design', '1');
    fd.append('parent', parent || ''); fd.append('layers', JSON.stringify(layers)); fd.append('checks', JSON.stringify(checks));
    fd.append('width', '2000'); fd.append('height', '2000');
    return studio(fd, true);
  };
  const del = async (a) => {
    if (!(await confirmDialog('Delete this photo from Studio?', { confirmText: 'Delete', danger: true }))) return;
    try { await rpc('api_amz_studio_delete', { p_id: a.id }); load(); } catch (e) { showToast(e.message, 'error'); }
  };

  const product = d?.product;
  const images = product?.images || [];
  const current = slot === 'swatch' ? product?.swatch : images[Number(slot) - 1]?.url;
  const meta = SLOTS.find((s) => s.id === slot);
  const assets = d?.assets || [];
  const options = useMemo(() => assets.filter((a) => fits(slot, a)), [assets, slot]);
  const inputs = useMemo(() => assets.filter((a) => (slot === 'swatch' ? ['upload', 'cutout'].includes(a.kind) : ['upload', 'cutout'].includes(a.kind)) && !fits(slot, a)), [assets, slot]);
  const waiting = (d?.jobs || []).filter((j) => ['waiting', 'working'].includes(j.status));
  const failed = (d?.jobs || []).filter((j) => j.status === 'failed').slice(0, 2);

  return (
    <div className="space-y-3">
      <div className="glass-card p-3 flex flex-wrap items-center gap-2">
        <select className="glass-input px-3 py-2 text-sm flex-1 min-w-[220px]" value={sku} onChange={(e) => setSku(e.target.value)} aria-label="Product">
          {(d?.products || []).map((p) => <option key={p.sku} value={p.sku}>{(p.title || p.sku).slice(0, 70)}{p.color ? ` · ${p.color}` : ''}</option>)}
        </select>
        <input ref={fileRef} type="file" accept="image/jpeg,image/png" multiple className="hidden" onChange={(e) => upload(e.target.files)} />
        <button type="button" className="glass-btn px-4 py-2 text-sm inline-flex items-center gap-2" disabled={busy || !sku} onClick={() => fileRef.current?.click()}><Icon name="plus" size={15} />Upload photos</button>
        <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" disabled title="Part 4: 3D and Reels videos">Video (soon)</button>
        <span className={`studio-mac ${d?.mac_online ? 'is-on' : ''}`} title="Photo jobs run on your Mac Mini">{d?.mac_online ? 'Mac online' : 'Mac offline: jobs wait'}{waiting.length ? ` · ${waiting.length} working` : ''}</span>
      </div>
      <div className="text-xs text-glass-secondary px-1">Tip: daylight near a window, a plain sheet, phone held straight. Front, back, spine, open pages and a name close-up. JPG or PNG.</div>
      {failed.map((j) => <div key={j.id} className="glass-card px-3 py-2 text-xs" style={{ color: '#C4261D' }}>{j.kind === 'cutout' ? 'Cut-out' : j.kind === 'main' ? 'Main photo' : j.kind === 'swatch' ? 'Swatch' : 'Photo check'} failed: {j.error}</div>)}
      {!d ? <div className="text-center text-glass-muted py-10 text-sm">Loading…</div> : (
        <div className="studio-grid">
          <div className="glass-card p-2 studio-slots" role="tablist" aria-label="Photo slots">
            {SLOTS.map((s) => {
              const img = s.id === 'swatch' ? product?.swatch : images[Number(s.id) - 1]?.url;
              const sent = assets.find((a) => a.status === 'sent' && a.meta?.sent_slot === s.id);
              return (
                <button key={s.id} type="button" role="tab" aria-selected={slot === s.id} className={`studio-slot ${slot === s.id ? 'is-on' : ''}`} onClick={() => setSlot(s.id)}>
                  <span className="studio-slot-img">{img ? <img src={img} alt="" loading="lazy" /> : <span className="text-glass-muted text-[10px]">empty</span>}</span>
                  <span className="min-w-0 text-left"><span className="block text-sm font-medium truncate">{s.label}</span>
                    {s.id === 'swatch' && product?.swatch_flagged && <span className="block text-[11px]" style={{ color: '#C4261D' }}>Amazon flags it</span>}
                    {sent && <span className="block text-[11px]" style={{ color: '#1E7B34' }}>New one in Decisions</span>}</span>
                </button>
              );
            })}
          </div>
          <div className="space-y-3 min-w-0">
            <div className="glass-card p-4 space-y-3">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div><div className="font-bold">{meta.label}</div><div className="text-xs text-glass-secondary">{meta.hint}</div></div>
                {current && <a href={current} target="_blank" rel="noopener noreferrer" className="text-xs font-semibold" style={{ color: 'var(--accent)' }}>Current on Amazon ↗</a>}
              </div>
              {options.length === 0 ? (
                <div className="text-sm text-glass-secondary rounded-xl px-3 py-4 text-center" style={{ background: 'rgba(118,118,128,0.06)' }}>
                  {slot === '1' ? 'Upload a photo, make a cut-out, then "Make main photo". The best ones appear here.'
                    : slot === 'swatch' ? 'Upload a cover photo, then "Choose swatch area".'
                    : 'Upload a photo (or make a main photo), then "Add text & pointers". Templates: features, size, inside pages, gift ideas.'}
                </div>
              ) : (
                <div className="studio-cards">{options.map((a) => <AssetCard key={a.id} a={a} url={urls[a.id]} slot={slot} canSend={d.can_send} busy={busy}
                  onJob={job} onSend={send} onDelete={del} onSwatch={(x) => setPicker(x)} onDesign={openDesigner} />)}</div>
              )}
              {d.can_send && assets.some((a) => a.status === 'sent') && goDecisions && <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={goDecisions}>Review in Decisions →</button>}
            </div>
            {inputs.length > 0 && (
              <div className="glass-card p-4 space-y-2">
                <div className="font-semibold text-sm">Your photos and cut-outs</div>
                <div className="studio-cards">{inputs.map((a) => <AssetCard key={a.id} a={a} url={urls[a.id]} slot={slot} canSend={false} busy={busy}
                  onJob={job} onSend={send} onDelete={del} onSwatch={(x) => setPicker(x)} onDesign={openDesigner} />)}</div>
              </div>
            )}
          </div>
        </div>
      )}
      {designer && <Designer sku={sku} base={designer.base} baseUrl={designer.baseUrl} upload={uploadDesign} onClose={() => setDesigner(null)} onSaved={load} />}
      {picker && <SwatchPicker asset={picker} url={urls[picker.id]} onClose={() => setPicker(null)} onPick={(a, box) => { setPicker(null); job('swatch', a, { box }); }} />}
    </div>
  );
}
