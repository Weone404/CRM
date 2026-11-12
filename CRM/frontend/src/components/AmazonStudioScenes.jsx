import { useEffect, useRef, useState } from 'react';
import { showToast } from '../utils/toast';
import { Modal } from './AmazonDecisions';

// Studio part 3: lifestyle scenes (your real cut-out on a free Pexels photo or an AI background made on your Mac)
// and the Guide (competitor photo study, brand kit, shoot list). Nothing here reaches Amazon by itself.

const THEMES = [
  ['desk', 'Desk', 'wooden desk table top'], ['gift', 'Gift', 'gift wrapping table background'], ['cafe', 'Café', 'cafe table coffee'],
  ['office', 'Office', 'office desk workspace'], ['festive', 'Festive', 'diwali diya table'], ['nature', 'Nature', 'wooden bench garden'],
];

// ---------------------------------------------------------------- scene picker
export function ScenePicker({ cut, cutUrl, studio, pexelsReady, aiStatus, backgrounds, urls, busy, onClose, onMake, onAi }) {
  const [tab, setTab] = useState(pexelsReady ? 'stock' : 'ai');
  const [theme, setTheme] = useState('desk');
  const [query, setQuery] = useState('');
  const [photos, setPhotos] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [bg, setBg] = useState(null);                  // {source:'pexels', photo} | {source:'ai', asset}
  const [pos, setPos] = useState({ x: 0.5, y: 0.55 });
  const [scale, setScale] = useState(0.5);
  const [note, setNote] = useState(true);
  const [words, setWords] = useState('');
  const stage = useRef(null);
  const dragging = useRef(false);

  const search = async (q, p = 1) => {
    if (!pexelsReady) return;
    setLoading(true);
    try { const r = await studio({ action: 'bg_search', query: q, page: p }); setPhotos((x) => (p === 1 ? r.photos : [...x, ...r.photos])); setPage(p); }
    catch (e) { showToast(e.message, 'error'); } finally { setLoading(false); }
  };
  useEffect(() => { if (tab === 'stock') search(THEMES.find((t) => t[0] === theme)[2]); }, [tab, theme]); // eslint-disable-line react-hooks/exhaustive-deps

  const ratio = cut.width && cut.height ? cut.height / cut.width : 1.3;
  let w = scale; let h = w * ratio;
  if (h > 0.85) { h = 0.85; w = h / ratio; }
  const left = Math.min(Math.max(pos.x - w / 2, 0.02), 0.98 - w);
  const top = Math.min(Math.max(pos.y - h / 2, 0.02), 0.98 - h);
  const bgUrl = bg?.source === 'pexels' ? bg.photo.preview || bg.photo.thumb : bg?.source === 'ai' ? urls[bg.asset.id] : null;
  const at = (e) => { const r = stage.current.getBoundingClientRect(); return { x: Math.min(0.9, Math.max(0.1, (e.clientX - r.left) / r.width)), y: Math.min(0.9, Math.max(0.1, (e.clientY - r.top) / r.height)) }; };
  const make = () => {
    const params = { x: pos.x, y: pos.y, scale, note };
    if (bg.source === 'pexels') onMake({ ...params, bg: { source: 'pexels', url: bg.photo.url, credit: bg.photo.credit } });
    else onMake({ ...params, bg: { source: 'ai' } }, bg.asset.id);
  };
  const aiReady = aiStatus === 'ready';

  return (
    <Modal title="Make a lifestyle scene" onClose={onClose} wide>
      <div className="scene-picker">
        <div className="space-y-3 min-w-0">
          <div className="flex gap-1.5" role="tablist">
            {[['stock', 'Stock photos (Pexels)'], ['ai', 'AI backgrounds']].map(([v, l]) => (
              <button key={v} type="button" role="tab" aria-selected={tab === v} className={`cat-chip ${tab === v ? 'is-on' : ''}`} onClick={() => setTab(v)}>{l}</button>))}
          </div>
          <div className="flex flex-wrap gap-1.5">
            {THEMES.map(([v, l]) => <button key={v} type="button" className={`kw-chip ${theme === v ? 'is-on' : ''}`} onClick={() => setTheme(v)}>{l}</button>)}
          </div>
          {tab === 'stock' && (!pexelsReady ? (
            <div className="text-sm rounded-xl p-3" style={{ background: 'rgba(255,149,0,0.10)' }}>
              Add the free Pexels key once in Amazon › Settings (sign up at <a className="underline" href="https://www.pexels.com/api/" target="_blank" rel="noopener noreferrer">pexels.com/api</a>, copy “Your API key”).
            </div>
          ) : (
            <>
              <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (query.trim()) search(query.trim()); }}>
                <input className="glass-input px-3 py-1.5 text-sm flex-1" placeholder="Search backgrounds, e.g. marble table" value={query} maxLength={60} onChange={(e) => setQuery(e.target.value)} aria-label="Search backgrounds" />
                <button type="submit" className="glass-btn-ghost px-3 py-1.5 text-sm" disabled={loading}>Search</button>
              </form>
              <div className="scene-grid" data-bgs>
                {photos.map((p) => (
                  <button key={p.id} type="button" className={`scene-bg ${bg?.photo?.id === p.id ? 'is-on' : ''}`} onClick={() => setBg({ source: 'pexels', photo: p })} title={`${p.alt} · by ${p.credit.name}`}>
                    <img src={p.thumb} alt={p.alt} loading="lazy" /><span>{p.credit.name}</span>
                  </button>))}
              </div>
              {loading && <div className="text-xs text-glass-muted">Loading…</div>}
              {!loading && photos.length > 0 && <button type="button" className="text-xs font-semibold" style={{ color: 'var(--accent)' }} onClick={() => search(query.trim() || THEMES.find((t) => t[0] === theme)[2], page + 1)}>More</button>}
              <div className="text-[11px] text-glass-muted">Photos provided by <a href="https://www.pexels.com" target="_blank" rel="noopener noreferrer" className="underline">Pexels</a> (free licence). Photos showing people are left out.</div>
            </>
          ))}
          {tab === 'ai' && (
            <>
              <div className="text-xs text-glass-secondary">Your Mac makes an empty background (no people, text or logos) for the theme. Your real diary photo goes on top.</div>
              <div className="flex gap-2">
                <input className="glass-input px-3 py-1.5 text-sm flex-1" placeholder="Extra words (optional), e.g. teak wood, morning light" value={words} maxLength={120} onChange={(e) => setWords(e.target.value)} aria-label="Extra words" />
                <button type="button" className="glass-btn-ghost px-3 py-1.5 text-sm" disabled={busy} onClick={() => onAi({ theme, words })}>Make 2</button>
              </div>
              {!aiReady && <div className="text-[11px]" style={{ color: '#B25E00' }}>{aiStatus ? `Mac: ${aiStatus}` : 'First use sets up the free AI model on your Mac (one 33 GB download, 30-90 minutes; needs 45 GB free disk).'}</div>}
              <div className="scene-grid">
                {backgrounds.map((b) => (
                  <button key={b.id} type="button" className={`scene-bg ${bg?.asset?.id === b.id ? 'is-on' : ''}`} onClick={() => setBg({ source: 'ai', asset: b })} title={b.meta?.theme}>
                    {urls[b.id] ? <img src={urls[b.id]} alt="AI background" loading="lazy" /> : null}<span>{b.meta?.theme || 'AI'}</span>
                  </button>))}
                {backgrounds.length === 0 && <div className="text-xs text-glass-muted col-span-full">No AI backgrounds yet.</div>}
              </div>
            </>
          )}
        </div>
        <div className="space-y-2">
          <div ref={stage} className="scene-stage" style={bgUrl ? { backgroundImage: `url("${bgUrl}")` } : undefined} aria-label="Scene preview: drag to move the diary"
            onPointerDown={(e) => { if (!bg) return; dragging.current = true; stage.current.setPointerCapture(e.pointerId); setPos(at(e)); }}
            onPointerMove={(e) => { if (dragging.current) setPos(at(e)); }} onPointerUp={() => { dragging.current = false; }}>
            {!bg && <span className="text-xs text-glass-muted">Choose a background</span>}
            {bg && cutUrl && <img src={cutUrl} alt="" draggable={false} style={{ left: `${left * 100}%`, top: `${top * 100}%`, width: `${w * 100}%` }} />}
            {bg && note && <span className="scene-note">Props not included</span>}
          </div>
          <label className="flex items-center gap-2 text-xs">Size<input type="range" min={25} max={80} value={Math.round(scale * 100)} onChange={(e) => setScale(Number(e.target.value) / 100)} className="flex-1" aria-label="Diary size" /></label>
          <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={note} onChange={(e) => setNote(e.target.checked)} />“Props not included” note (keep it on when cups, pens or gifts are in the photo)</label>
          <div className="text-[10px] text-glass-muted">The Mac adds a soft shadow. Claude then checks it: believable, no people or logos, nothing that looks included but isn't.</div>
          <div className="flex justify-end gap-2">
            <button type="button" className="glass-btn-ghost px-4 py-2 text-sm" onClick={onClose}>Cancel</button>
            <button type="button" className="glass-btn px-5 py-2 text-sm" disabled={!bg || busy} onClick={make}>Make scene</button>
          </div>
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- guide
const FONTS = [['system', 'Clean (system)'], ['serif', 'Classic (serif)'], ['rounded', 'Friendly (rounded)']];
const SPOTS = [['none', 'Not on photos'], ['top-left', 'Top left'], ['top-right', 'Top right'], ['bottom-left', 'Bottom left'], ['bottom-right', 'Bottom right']];

export function Guide({ sku, studio, rpc, canEdit, onClose }) {
  const [g, setG] = useState(null);
  const [kw, setKw] = useState('');
  const [busy, setBusy] = useState(false);
  const [brand, setBrand] = useState(null);
  const load = async () => {
    try { const r = await rpc('api_amz_studio_guide', { p_sku: sku }); setG(r); setKw((k) => k || r.keyword || ''); setBrand((b) => b || r.brand); }
    catch (e) { showToast(e.message, 'error'); }
  };
  useEffect(() => { load(); }, [sku]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (!g?.study_running) return undefined; const t = setInterval(load, 5000); return () => clearInterval(t); }, [g?.study_running]); // eslint-disable-line react-hooks/exhaustive-deps
  const study = async () => {
    setBusy(true);
    try { const r = await studio({ action: 'study', sku, keyword: kw }); showToast(`Studying ${r.competitors} listings on your Mac (Claude looks at their photos).`, 'success'); load(); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const saveBrand = async () => {
    setBusy(true);
    try { const r = await rpc('api_amz_studio_brand_save', { p: brand }); setBrand(r); showToast('Brand kit saved', 'success'); }
    catch (e) { showToast(e.message, 'error'); } finally { setBusy(false); }
  };
  const s = g?.study;
  return (
    <Modal title="Photo guide" onClose={onClose} wide>
      {!g ? <div className="text-sm text-glass-muted py-6 text-center">Loading…</div> : (
        <div className="space-y-4" data-guide>
          <section className="space-y-2">
            <h4 className="font-semibold text-sm">1 · What top listings show</h4>
            <div className="flex flex-wrap gap-2">
              <input className="glass-input px-3 py-1.5 text-sm flex-1 min-w-[200px]" value={kw} maxLength={80} onChange={(e) => setKw(e.target.value)} aria-label="Search words buyers use" />
              <button type="button" className="glass-btn px-4 py-1.5 text-sm" disabled={busy || g.study_running || kw.trim().length < 3} onClick={study}>{g.study_running ? 'Studying…' : s ? 'Study again' : 'Study top listings'}</button>
            </div>
            <div className="text-[11px] text-glass-muted">Top 10 other listings from Amazon's own catalog search; Claude on your Mac names what each photo shows.</div>
            {s?.status === 'failed' && <div className="text-xs" style={{ color: '#C4261D' }}>Study failed: {s.error}</div>}
            {s?.status === 'done' && (
              <div className="space-y-2">
                <div className="text-sm">“{s.keyword}”: {s.competitors} listings, about <b>{s.avg_photos ?? '?'}</b> photos each. You have <b>{g.photos}</b>.</div>
                {(s.notes || []).length > 0 && <ul className="text-xs list-disc pl-5 space-y-0.5 text-glass-secondary">{s.notes.map((n, i) => <li key={i}>{n}</li>)}</ul>}
                <div className="guide-comp">{(s.items || []).map((it) => (
                  <a key={it.asin} href={`https://www.amazon.in/dp/${it.asin}`} target="_blank" rel="noopener noreferrer" title={it.title}>
                    {it.image ? <img src={it.image} alt="" loading="lazy" /> : null}<span>{it.photos} photos</span></a>))}</div>
              </div>
            )}
          </section>
          <section className="space-y-2">
            <h4 className="font-semibold text-sm">2 · Shoot list for this product</h4>
            <ul className="space-y-1.5">
              {g.shots.map((x) => (
                <li key={x.code} className="guide-shot" data-shot={x.code}>
                  <span className={`guide-tick ${x.have ? 'is-on' : x.have === false ? 'is-off' : ''}`} aria-label={x.have ? 'Have it' : x.have === false ? 'Missing' : 'Unknown'}>{x.have ? '✓' : x.have === false ? '✕' : '?'}</span>
                  <span className="min-w-0 flex-1"><span className="text-sm font-medium">{x.label}</span>
                    {x.competitors_pct != null && <span className="text-[11px] text-glass-muted"> · {x.competitors_pct}% of top listings</span>}
                    {x.ready_in_studio > 0 && <span className="text-[11px]" style={{ color: '#1E7B34' }}> · {x.ready_in_studio} ready in Studio</span>}
                    <span className="block text-[11px] text-glass-secondary">{x.tip}</span></span>
                </li>))}
            </ul>
            {!s && <div className="text-[11px] text-glass-muted">Run the study to see which of these you already have and what competitors show.</div>}
          </section>
          {brand && (
            <section className="space-y-2">
              <h4 className="font-semibold text-sm">3 · Brand kit <span className="text-[11px] font-normal text-glass-muted">used by Text & pointers on every product</span></h4>
              <div className="flex flex-wrap gap-3 items-center text-sm">
                <label className="flex items-center gap-2">Name<input className="glass-input px-2 py-1 text-sm w-36" value={brand.name} maxLength={30} disabled={!canEdit} onChange={(e) => setBrand({ ...brand, name: e.target.value })} /></label>
                <span className="flex items-center gap-1">Colours{brand.colors.map((c, i) => (
                  <input key={i} type="color" value={c} disabled={!canEdit} aria-label={`Colour ${i + 1}`} className="w-8 h-8 rounded" onChange={(e) => setBrand({ ...brand, colors: brand.colors.map((x, j) => (j === i ? e.target.value : x)) })} />))}</span>
                <select className="glass-input px-2 py-1 text-sm" value={brand.font} disabled={!canEdit} onChange={(e) => setBrand({ ...brand, font: e.target.value })} aria-label="Font">{FONTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
                <select className="glass-input px-2 py-1 text-sm" value={brand.name_spot} disabled={!canEdit} onChange={(e) => setBrand({ ...brand, name_spot: e.target.value })} aria-label="Brand name on photos">{SPOTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
                {canEdit && <button type="button" className="glass-btn-ghost px-3 py-1.5 text-sm" disabled={busy} onClick={saveBrand}>Save</button>}
              </div>
            </section>
          )}
        </div>
      )}
    </Modal>
  );
}
