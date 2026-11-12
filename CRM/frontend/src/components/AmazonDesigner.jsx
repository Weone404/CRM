import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../backend/supabaseClient';
import { showToast } from '../utils/toast';
import Icon from './icons';
import { Modal } from './AmazonDecisions';

// Studio part 2: text & pointers on photos 2-9 (Amazon allows no text on the main photo).
// One renderer draws both the preview and the saved 2000x2000 image, so what you see is exactly what is saved.
// Layers stay editable (saved with the design). Truth check runs on the server; readability and edges are checked here.

const S = 2000;
const FONT = '-apple-system, "SF Pro Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
const COLORS = [['Black', '#1d1d1f'], ['White', '#ffffff'], ['Brown', '#7A4A24'], ['Gold', '#A67C1A'], ['Blue', '#0062CC']];
const BGS = [['None', ''], ['White', '#ffffff'], ['Dark', '#1d1d1f'], ['Cream', '#F6EFE4']];
const PAGES = [['White', '#ffffff'], ['Cream', '#F6EFE4'], ['Light grey', '#F2F2F4']];
const rpc = async (fn, args) => { const { data, error } = await supabase.rpc(fn, args); if (error) throw new Error(error.message); return data; };

let uid = 0;
const L = (o) => ({ id: `l${Date.now().toString(36)}${uid++}`, size: 64, color: '#1d1d1f', bg: '#ffffff', weight: 700, ...o });

// ---------------------------------------------------------------- templates (wording only from the product's facts)
export function templateLayers(name, f = {}) {
  const c = (f.callouts || []).slice(0, 4);
  const sizeWord = f.facts?.size ? `${String(f.facts.size).toUpperCase()} size` : null;
  switch (name) {
    case 'features': {
      const spots = [[0.2, 0.18, 0.4, 0.3], [0.8, 0.32, 0.6, 0.4], [0.2, 0.62, 0.42, 0.58], [0.8, 0.8, 0.6, 0.72]];
      return c.map((t, i) => L({ type: 'pointer', text: t, x: spots[i][0], y: spots[i][1], tx: spots[i][2], ty: spots[i][3], size: 60 }));
    }
    case 'size':
      return [L({ type: 'text', text: 'Size', x: 0.5, y: 0.08, size: 110, bg: '' }),
        ...[sizeWord, f.dimensions, f.pages ? `${f.pages} pages` : null].filter(Boolean)
          .map((t, i) => L({ type: 'badge', text: t, x: 0.5, y: 0.8 + i * 0.075, size: 66, bg: '#1d1d1f', color: '#ffffff' }))];
    case 'inside':
      return [L({ type: 'text', text: 'Inside the diary', x: 0.5, y: 0.08, size: 100, bg: '' }),
        ...(f.special_features || []).slice(0, 3).map((t, i) => L({ type: 'badge', text: t, x: 0.5, y: 0.8 + i * 0.075, size: 62 }))];
    case 'name':
      return f.facts?.personal ? [L({ type: 'text', text: 'Your name on the cover', x: 0.5, y: 0.08, size: 100, bg: '' }),
        L({ type: 'pointer', text: 'Personalised with your name', x: 0.5, y: 0.88, tx: 0.5, ty: 0.62, size: 64 })] : [];
    case 'gift':
      return [L({ type: 'text', text: 'A gift they will use every day', x: 0.5, y: 0.08, size: 92, bg: '' }),
        ...['New Year', 'Birthday', 'Corporate gifting'].map((t, i) => L({ type: 'badge', text: t, x: 0.2 + i * 0.3, y: 0.9, size: 58, bg: '#F6EFE4' }))];
    case 'box':
      return [L({ type: 'text', text: 'What’s in the box', x: 0.5, y: 0.08, size: 100, bg: '' }),
        L({ type: 'badge', text: (f.facts?.pack || 1) > 1 ? `${f.facts.pack} diaries` : '1 diary', x: 0.5, y: 0.9, size: 70, bg: '#1d1d1f', color: '#ffffff' })];
    default: return [];
  }
}
const TEMPLATES = [['', 'Blank'], ['features', 'Features with pointers'], ['size', 'Size'], ['inside', 'Inside pages'], ['name', 'Your name on the cover'],
  ['gift', 'Gift ideas'], ['box', 'What’s in the box']];

// ---------------------------------------------------------------- renderer (shared by preview and export)
function wrap(ctx, text, maxW) {
  const words = String(text || '').split(/\s+/); const lines = []; let cur = '';
  for (const w of words) { const t = cur ? `${cur} ${w}` : w; if (ctx.measureText(t).width > maxW && cur) { lines.push(cur); cur = w; } else cur = t; }
  if (cur) lines.push(cur);
  return lines.slice(0, 4);
}
function rr(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
function labelBox(ctx, l) {
  ctx.font = `${l.weight || 700} ${l.size}px ${FONT}`;
  const lines = wrap(ctx, l.text, S * (l.type === 'text' ? 0.86 : 0.42));
  const w = Math.max(...lines.map((t) => ctx.measureText(t).width), 10);
  const lh = l.size * 1.18; const padX = l.bg ? l.size * 0.55 : 0; const padY = l.bg ? l.size * 0.32 : 0;
  const bw = w + padX * 2; const bh = lines.length * lh + padY * 2;
  return { lines, lh, padX, padY, x0: l.x * S - bw / 2, y0: l.y * S - bh / 2, w: bw, h: bh };
}
export function render(ctx, { img, page = '#ffffff', fit = 'contain', layers = [], selected = null }) {
  ctx.save();
  ctx.fillStyle = page; ctx.fillRect(0, 0, S, S);
  if (img) {
    const r = fit === 'cover' ? Math.max(S / img.width, S / img.height) : Math.min((S * 0.78) / img.width, (S * 0.78) / img.height);
    const w = img.width * r; const h = img.height * r;
    ctx.drawImage(img, (S - w) / 2, (S - h) / 2, w, h);
  }
  const boxes = [];
  for (const l of layers) {
    const b = labelBox(ctx, l);
    if (l.type === 'pointer') {
      const tx = l.tx * S; const ty = l.ty * S;
      const ax = Math.max(b.x0, Math.min(tx, b.x0 + b.w)); const ay = Math.max(b.y0, Math.min(ty, b.y0 + b.h));
      ctx.strokeStyle = l.color === '#ffffff' ? '#ffffff' : '#1d1d1f'; ctx.lineWidth = 7; ctx.lineCap = 'round';
      ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(tx, ty); ctx.stroke();
      ctx.fillStyle = '#ffffff'; ctx.beginPath(); ctx.arc(tx, ty, 22, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = ctx.strokeStyle; ctx.beginPath(); ctx.arc(tx, ty, 13, 0, Math.PI * 2); ctx.fill();
      boxes.push({ id: l.id, part: 'tip', x0: tx - 40, y0: ty - 40, x1: tx + 40, y1: ty + 40 });
    }
    if (l.bg) {
      ctx.shadowColor = 'rgba(0,0,0,0.12)'; ctx.shadowBlur = 24; ctx.shadowOffsetY = 6;
      ctx.fillStyle = l.bg; rr(ctx, b.x0, b.y0, b.w, b.h, Math.min(b.h / 2, l.size * 0.9)); ctx.fill();
      ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0; ctx.shadowOffsetY = 0;
    }
    ctx.fillStyle = l.color; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.font = `${l.weight || 700} ${l.size}px ${FONT}`;
    b.lines.forEach((t, i) => ctx.fillText(t, l.x * S, b.y0 + b.padY + b.lh * (i + 0.5)));
    if (selected === l.id) { ctx.setLineDash([16, 12]); ctx.strokeStyle = '#007AFF'; ctx.lineWidth = 5; ctx.strokeRect(b.x0 - 12, b.y0 - 12, b.w + 24, b.h + 24); ctx.setLineDash([]); }
    boxes.push({ id: l.id, part: 'label', x0: b.x0, y0: b.y0, x1: b.x0 + b.w, y1: b.y0 + b.h });
  }
  ctx.restore();
  return boxes;
}

// ---------------------------------------------------------------- checks made in the browser
const lum = (hex) => { const n = parseInt(hex.slice(1), 16); const c = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const lumRGB = (r, g, b) => lum(`#${((1 << 24) | (r << 16) | (g << 8) | b).toString(16).slice(1)}`);
export function localChecks(ctx, layers, imgW) {
  const out = []; const short = (t) => (t.length > 22 ? `${t.slice(0, 22)}…` : t);
  const boxes = layers.map((l) => ({ l, b: labelBox(ctx, l) }));
  for (const { l, b } of boxes) {
    if (l.size < 56) out.push({ code: 'small', ok: false, message: `"${short(l.text)}" is too small to read on a phone (make it 56+)` });
    let bgL;
    if (l.bg) bgL = lum(l.bg);
    else {
      const x = Math.max(0, Math.floor(b.x0)); const y = Math.max(0, Math.floor(b.y0));
      const d = ctx.getImageData(x, y, Math.max(1, Math.min(S - x, Math.ceil(b.w))), Math.max(1, Math.min(S - y, Math.ceil(b.h)))).data;
      let r = 0, g = 0, bl = 0, n = 0; for (let i = 0; i < d.length; i += 64) { r += d[i]; g += d[i + 1]; bl += d[i + 2]; n++; }
      bgL = lumRGB(Math.round(r / n), Math.round(g / n), Math.round(bl / n));
    }
    const fg = lum(l.color); const ratio = (Math.max(fg, bgL) + 0.05) / (Math.min(fg, bgL) + 0.05);
    if (ratio < 4.5) out.push({ code: 'contrast', ok: false, message: `"${short(l.text)}" is hard to read on its background (add a background)` });
    if (b.x0 < S * 0.03 || b.y0 < S * 0.03 || b.x0 + b.w > S * 0.97 || b.y0 + b.h > S * 0.97) out.push({ code: 'edge', ok: false, message: `"${short(l.text)}" is too close to the edge` });
  }
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const a = boxes[i].b; const c = boxes[j].b;
    if (a.x0 < c.x0 + c.w && c.x0 < a.x0 + a.w && a.y0 < c.y0 + c.h && c.y0 < a.y0 + a.h) out.push({ code: 'overlap', ok: false, message: `"${short(boxes[i].l.text)}" overlaps "${short(boxes[j].l.text)}"` });
  }
  const words = layers.reduce((n, l) => n + String(l.text || '').split(/\s+/).filter(Boolean).length, 0);
  if (words > 40) out.push({ code: 'words', ok: false, message: `${words} words: keep it under 40 so it reads at a glance` });
  if (imgW && imgW < 1600) out.push({ code: 'base', ok: false, message: 'The base photo is small: the saved image may look soft when zoomed' });
  return out;
}

// ---------------------------------------------------------------- editor
export function Designer({ sku, base, baseUrl, upload, onClose, onSaved }) {
  const view = useRef(null);
  const [img, setImg] = useState(null);
  const [imgErr, setImgErr] = useState(false);
  const [facts, setFacts] = useState(null);
  const [layers, setLayers] = useState(() => (Array.isArray(base.layers) ? base.layers : []));
  const [sel, setSel] = useState(null);
  const [page, setPage] = useState('#ffffff');
  const [fit, setFit] = useState(base.kind === 'upload' ? 'cover' : 'contain');
  const [truth, setTruth] = useState([]);
  const [local, setLocal] = useState([]);
  const [busy, setBusy] = useState(false);
  const drag = useRef(null);
  const boxes = useRef([]);

  useEffect(() => { rpc('api_amz_studio_facts', { p_sku: sku }).then(setFacts).catch(() => setFacts({ callouts: [] })); }, [sku]);
  useEffect(() => {
    if (!baseUrl) { setImgErr(true); return; }
    const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => setImg(i); i.onerror = () => setImgErr(true); i.src = baseUrl;
  }, [baseUrl]);
  const paint = useCallback(() => {
    const c = view.current; if (!c) return;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    boxes.current = render(ctx, { img, page, fit, layers, selected: sel });
  }, [img, page, fit, layers, sel]);
  useEffect(() => { paint(); }, [paint]);
  // checks: readability here (measured on a clean render), truth on the server
  useEffect(() => {
    const t = setTimeout(async () => {
      const c = document.createElement('canvas'); c.width = S; c.height = S; const ctx = c.getContext('2d', { willReadFrequently: true });
      render(ctx, { img, page, fit, layers: [] });
      setLocal(localChecks(ctx, layers, img ? Math.max(img.width, img.height) : 0));
      const texts = layers.map((l) => l.text).filter(Boolean);
      if (texts.length) rpc('api_amz_studio_truth', { p_sku: sku, p_texts: texts }).then(setTruth).catch(() => {}); else setTruth([]);
    }, 450);
    return () => clearTimeout(t);
  }, [layers, img, page, fit, sku]);

  const pt = (e) => { const r = view.current.getBoundingClientRect(); return { x: ((e.clientX - r.left) / r.width) * S, y: ((e.clientY - r.top) / r.height) * S }; };
  const hit = (p) => [...boxes.current].reverse().find((b) => p.x >= b.x0 && p.x <= b.x1 && p.y >= b.y0 && p.y <= b.y1);
  const down = (e) => { const p = pt(e); const h = hit(p); if (!h) { setSel(null); return; } e.preventDefault(); view.current.setPointerCapture(e.pointerId); setSel(h.id); const l = layers.find((x) => x.id === h.id); drag.current = { ...h, dx: p.x - (h.part === 'tip' ? l.tx : l.x) * S, dy: p.y - (h.part === 'tip' ? l.ty : l.y) * S }; };
  const move = (e) => {
    if (!drag.current) return; const p = pt(e); const d = drag.current;
    const nx = Math.min(0.98, Math.max(0.02, (p.x - d.dx) / S)); const ny = Math.min(0.98, Math.max(0.02, (p.y - d.dy) / S));
    setLayers((ls) => ls.map((l) => (l.id !== d.id ? l : d.part === 'tip' ? { ...l, tx: nx, ty: ny } : { ...l, x: nx, y: ny })));
  };
  const up = () => { drag.current = null; };
  const add = (type, text = '') => {
    const l = L({ type, text: text || (type === 'pointer' ? 'Detail' : type === 'badge' ? 'Badge' : 'Heading'), x: 0.5, y: type === 'text' ? 0.1 : 0.85,
      ...(type === 'pointer' ? { x: 0.22, y: 0.2 + (layers.length % 4) * 0.18, tx: 0.42, ty: 0.3 + (layers.length % 4) * 0.12, size: 60 } : {}),
      ...(type === 'text' ? { size: 100, bg: '' } : {}) });
    setLayers((ls) => [...ls, l]); setSel(l.id);
  };
  const upd = (id, patch) => setLayers((ls) => ls.map((l) => (l.id === id ? { ...l, ...patch } : l)));
  const cur = layers.find((l) => l.id === sel);
  const truthBad = truth.filter((t) => !t.ok);
  const problems = useMemo(() => [...truthBad.flatMap((t) => t.problems.map((m) => ({ code: 'truth', message: `"${t.text}": ${m}` }))), ...local], [truthBad, local]);
  const raw = Math.max(0, 100 - truthBad.reduce((n, t) => n + t.problems.length, 0) * 30 - Math.min(local.length, 4) * 10 - (layers.length > 7 ? 10 : 0));
  const estimate = truthBad.length ? Math.min(raw, 40) : raw;            // a false claim can never be sent

  const save = async () => {
    if (!layers.length) { showToast('Add some text or a pointer first', 'error'); return; }
    setBusy(true);
    try {
      const c = document.createElement('canvas'); c.width = S; c.height = S;
      render(c.getContext('2d'), { img, page, fit, layers });
      const blob = await new Promise((ok, bad) => c.toBlob((b) => (b ? ok(b) : bad(new Error('Could not make the image'))), 'image/jpeg', 0.92));
      const r = await upload({ blob, layers, checks: local, parent: base.id });
      showToast(`Saved. Score ${r.score}/100${r.score < 70 ? ': fix the issues before sending' : ''}`, r.score < 70 ? 'error' : 'success');
      onSaved(); onClose();
    } catch (e) { showToast(e.message.includes('tainted') ? 'The photo could not be read. Reload Studio and try again.' : e.message, 'error'); }
    finally { setBusy(false); }
  };

  return (
    <Modal title="Text & pointers" onClose={onClose} wide>
      <div className="designer">
        <div className="designer-stage">
          <canvas ref={view} width={S} height={S} className="designer-canvas" onPointerDown={down} onPointerMove={move} onPointerUp={up} aria-label="Design canvas: drag labels and pointer tips" />
          {imgErr && <div className="text-[11px] text-glass-muted mt-1">The photo could not be loaded; text is shown on a plain background.</div>}
          <div className="text-[11px] text-glass-muted mt-1">Drag a label to move it; drag the dot to point at the detail.</div>
        </div>
        <div className="designer-side space-y-3">
          <div className="flex flex-wrap gap-2">
            <select className="glass-input px-2 py-1.5 text-sm flex-1 min-w-[150px]" aria-label="Template" defaultValue=""
              onChange={(e) => { if (e.target.value) { const t = templateLayers(e.target.value, facts || {}); if (!t.length) showToast('Not available for this product (its details do not support it)', 'error'); else { setLayers(t); setSel(null); } } }}>
              {TEMPLATES.map(([v, l]) => <option key={v} value={v}>{v ? `Template: ${l}` : 'Choose a template…'}</option>)}
            </select>
          </div>
          <div className="flex flex-wrap gap-1.5">
            <button type="button" className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => add('text')}>+ Heading</button>
            <button type="button" className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => add('pointer')}>+ Pointer</button>
            <button type="button" className="glass-btn-ghost px-3 py-1.5 text-xs" onClick={() => add('badge')}>+ Badge</button>
          </div>
          {facts?.callouts?.length > 0 && (
            <div>
              <div className="text-[11px] text-glass-muted mb-1">From this product's key points (tap to add a pointer)</div>
              <div className="flex flex-wrap gap-1">{facts.callouts.map((t) => <button key={t} type="button" className="kw-chip" onClick={() => add('pointer', t)}>+ {t}</button>)}</div>
            </div>
          )}
          {cur && (
            <div className="rounded-xl p-2.5 space-y-2" style={{ background: 'rgba(0,122,255,0.06)' }}>
              <input className="glass-input w-full px-2.5 py-1.5 text-sm" value={cur.text} maxLength={80} onChange={(e) => upd(cur.id, { text: e.target.value })} aria-label="Text" />
              <label className="flex items-center gap-2 text-xs">Size<input type="range" min={40} max={160} value={cur.size} onChange={(e) => upd(cur.id, { size: Number(e.target.value) })} className="flex-1" /><span className="w-8 text-right">{cur.size}</span></label>
              <div className="flex flex-wrap gap-1 items-center text-xs">Text:{COLORS.map(([n, v]) => <button key={n} type="button" title={n} aria-label={`Text ${n}`} className={`swatch-dot ${cur.color === v ? 'is-on' : ''}`} style={{ background: v }} onClick={() => upd(cur.id, { color: v })} />)}</div>
              <div className="flex flex-wrap gap-1 items-center text-xs">Background:{BGS.map(([n, v]) => <button key={n} type="button" className={`px-2 py-0.5 rounded-full border text-[11px] ${cur.bg === v ? 'border-blue-500 font-semibold' : 'border-transparent'}`} onClick={() => upd(cur.id, { bg: v })}>{n}</button>)}</div>
              <button type="button" className="text-xs" style={{ color: '#C4261D' }} onClick={() => { setLayers((ls) => ls.filter((l) => l.id !== cur.id)); setSel(null); }}>Delete this label</button>
            </div>
          )}
          <div className="flex flex-wrap gap-1 items-center text-xs">Page:{PAGES.map(([n, v]) => <button key={n} type="button" className={`px-2 py-0.5 rounded-full border text-[11px] ${page === v ? 'border-blue-500 font-semibold' : 'border-transparent'}`} onClick={() => setPage(v)}>{n}</button>)}
            <span className="ml-2">Photo:</span>{[['contain', 'Fit'], ['cover', 'Fill']].map(([v, n]) => <button key={v} type="button" className={`px-2 py-0.5 rounded-full border text-[11px] ${fit === v ? 'border-blue-500 font-semibold' : 'border-transparent'}`} onClick={() => setFit(v)}>{n}</button>)}</div>
          <div className="rounded-xl p-2.5 text-xs space-y-1" style={{ background: 'rgba(118,118,128,0.06)' }} data-checks>
            <div className="flex items-center justify-between font-semibold"><span>Checks</span><span className="studio-score static" style={{ position: 'static' }}>{estimate}</span></div>
            {problems.length === 0 ? <div style={{ color: '#1E7B34' }}>✓ True to the product, readable on a phone, inside the edges</div>
              : problems.slice(0, 8).map((p, i) => <div key={i} style={{ color: p.code === 'truth' ? '#C4261D' : '#B25E00' }}>{p.code === 'truth' ? '✕' : '!'} {p.message}</div>)}
            <div className="text-[10px] text-glass-muted">Score under 70 can't be sent. Nothing goes to Amazon until you approve it in Decisions.</div>
          </div>
          <div className="flex justify-end gap-2">
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={onClose}>Cancel</button>
            <button type="button" className="glass-btn px-5 py-2 text-sm" disabled={busy || !layers.length} onClick={save}>{busy ? 'Saving…' : 'Save design'}</button>
          </div>
        </div>
      </div>
    </Modal>
  );
}
