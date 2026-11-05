import { useEffect, useRef } from 'react';
import * as THREE from 'three';
import { AIRFIELD_SQUARES } from '../data/airfields';

// Live 3D Earth for the FlightBridge School Detector (and, quieter, behind the sign-in screens).
// The Earth is real satellite imagery: NASA Blue Marble (shaded relief + sea floor) for the whole globe, bundled in
// /public/globe, and sharp Landsat imagery (NASA GIBS, free, no key) fetched for the area around each square the camera
// zooms into. If the imagery can't load, a dotted globe is shown instead.
//
// Detector mode runs a camera "tour" over the squares the world search has just searched:
//   * it starts on the newest square (live), then replays the recent ones and the overview, then repeats;
//   * on each square: the camera zooms in at an angle, a scan line sweeps the square, every school found pops up as a
//     node, nodes wire themselves to their nearest neighbours like a neural network, pulses run along the links and the
//     newest school names appear next to their nodes;
//   * next square close by: the camera glides there while a link grows from the old square to the new one;
//     far away: it zooms all the way out, turns the globe, and zooms back in.
// Drag to look around (the tour waits, then carries on). Plain three.js. Pauses when off-screen or the tab is hidden.
// With "reduce motion" switched on, it shows the newest square still, with no animation.

const DEG = Math.PI / 180;
const SCAN = 1.8;          // seconds the scan line takes to cross a square
const DWELL = 7.5;         // seconds spent on each square
const OVERVIEW = 6;        // seconds of world view between rounds

const P = {
  halo: '#6cb4ff', haloStrength: 0.9, land: '#5eead4', landAlpha: 0.55, grid: '#ffffff', gridAlpha: 0.06,
  fine: '#a5f3fc', fineAlpha: 0.2, school: { 2: '#4ade80', 1: '#fbbf24', 0: '#22d3ee' }, edge: '#67e8f9', probe: '#fb7185',
  link: '#c4b5fd', scan: '#fb7185', pulse: '#ffffff', blend: THREE.AdditiveBlending,
};
const GIBS = 'https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap'
  + '&LAYERS=Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual&STYLES=&SRS=EPSG:4326&FORMAT=image/jpeg';

// colour treatment shared by the globe and the close-up patches (a little richer, like Apple Maps)
const GRADE = `
  vec3 grade(vec3 c) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(vec3(l), c, 1.22);
    return clamp((c - 0.5) * 1.08 + 0.53, 0.0, 1.0);
  }
  vec3 shade(vec3 c, vec3 n, vec3 v) {
    float ndl = max(0.0, dot(n, normalize(vec3(-0.45, 0.55, 0.72))));
    vec3 col = c * (0.5 + 0.62 * ndl);
    float rim = pow(1.0 - max(0.0, dot(n, v)), 3.0);
    return mix(col, vec3(0.55, 0.76, 1.0), rim * 0.6);
  }`;
const EARTH_VERT = `
  varying vec2 vUv; varying vec3 vN; varying vec3 vV;
  void main() {
    vUv = uv;
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vN = normalize(normalMatrix * normal); vV = normalize(-mv.xyz);
    gl_Position = projectionMatrix * mv;
  }`;
const EARTH_FRAG = `
  uniform sampler2D uMap; uniform float uReady; varying vec2 vUv; varying vec3 vN; varying vec3 vV;
  ${GRADE}
  void main() {
    vec3 c = mix(vec3(0.03, 0.09, 0.18), grade(texture2D(uMap, vUv).rgb), uReady);
    gl_FragColor = vec4(shade(c, vN, vV), 1.0);
  }`;
// close-up Landsat patch: dark water and missing pixels fall back to the Blue Marble globe underneath; soft edges
const PATCH_FRAG = `
  uniform sampler2D uMap; uniform sampler2D uBase; uniform vec4 uBox; uniform float uFade;
  varying vec2 vUv; varying vec3 vN; varying vec3 vV;
  ${GRADE}
  void main() {
    vec3 c = texture2D(uMap, vUv).rgb;
    vec2 bu = vec2((uBox.y + vUv.x * (uBox.w - uBox.y) + 180.0) / 360.0, (uBox.x + vUv.y * (uBox.z - uBox.x) + 90.0) / 180.0);
    vec3 b = texture2D(uBase, bu).rgb;
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    float water = (1.0 - smoothstep(0.06, 0.14, l)) * step(c.r, c.b + 0.02);
    float none = 1.0 - smoothstep(0.0, 0.03, max(c.r, max(c.g, c.b)));
    c = mix(c * 1.12, b, max(water, none));
    float edge = smoothstep(0.0, 0.08, vUv.x) * smoothstep(0.0, 0.08, vUv.y) * smoothstep(0.0, 0.08, 1.0 - vUv.x) * smoothstep(0.0, 0.08, 1.0 - vUv.y);
    gl_FragColor = vec4(shade(grade(c), vN, vV), edge * uFade);
  }`;

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const wrap = (d) => ((((d + 180) % 360) + 360) % 360) - 180;

function vec(lat, lng, r = 1) {
  const phi = (90 - lat) * DEG;
  const theta = (lng + 180) * DEG;
  return new THREE.Vector3(-r * Math.sin(phi) * Math.cos(theta), r * Math.cos(phi), r * Math.sin(phi) * Math.sin(theta));
}

function angDist(a, b) {                       // great-circle distance in degrees
  const p1 = a.lat * DEG; const p2 = b.lat * DEG; const dl = (b.lng - a.lng) * DEG;
  return Math.acos(Math.min(1, Math.sin(p1) * Math.sin(p2) + Math.cos(p1) * Math.cos(p2) * Math.cos(dl))) / DEG;
}

function arcPath(la1, lo1, la2, lo2, base = 1.004, liftK = 0.2, segs = 10) {
  const a = vec(la1, lo1, 1); const b = vec(la2, lo2, 1);
  const lift = a.distanceTo(b) * liftK;
  const out = [];
  for (let s = 0; s <= segs; s++) {
    const k = s / segs;
    const p = a.clone().lerp(b, k);
    if (p.lengthSq() < 1e-6) p.set(0, 1, 0);
    out.push(p.normalize().multiplyScalar(base + Math.sin(Math.PI * k) * lift));
  }
  return out;
}

// ------------------------------------------------------------------ shaders
const DOT_VERT = `
  attribute float size; attribute vec3 color; attribute float born;
  uniform float uPixel; uniform float uMax; uniform float uNow; uniform float uPop;
  varying vec3 vColor; varying float vFacing; varying float vPop;
  void main() {
    vColor = color;
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vec3 n = normalize(normalMatrix * normalize(position));
    vFacing = dot(n, normalize(-mv.xyz));
    float k = uPop > 0.5 ? clamp((uNow - born) / 0.45, 0.0, 1.0) : 1.0;
    vPop = k;
    float s = k + sin(k * 3.14159) * 0.8;
    gl_PointSize = min(size * uPixel * (2.6 / -mv.z), uMax * uPixel) * s;
    gl_Position = projectionMatrix * mv;
  }`;
const DOT_FRAG = `
  uniform float uOpacity; uniform float uRing; uniform float uFade;
  varying vec3 vColor; varying float vFacing; varying float vPop;
  void main() {
    vec2 c = gl_PointCoord - 0.5; float d = length(c);
    if (d > 0.5 || vPop <= 0.0) discard;
    float a = 1.0 - smoothstep(0.30, 0.42, d);
    if (uRing > 0.5) a = max(1.0 - smoothstep(0.17, 0.23, d), smoothstep(0.33, 0.38, d) * (1.0 - smoothstep(0.44, 0.5, d)));
    a *= uOpacity * uFade * smoothstep(-0.05, 0.2, vFacing);
    if (a < 0.01) discard;
    gl_FragColor = vec4(vColor, a);
  }`;
const EDGE_VERT = `
  attribute float side; attribute float born; attribute float dur; attribute float alpha;
  uniform float uNow; varying float vSide; varying float vK; varying float vA;
  void main() {
    vSide = side; vA = alpha; vK = clamp((uNow - born) / dur, 0.0, 1.0);
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }`;
const EDGE_FRAG = `
  uniform vec3 uColor; uniform float uFade; varying float vSide; varying float vK; varying float vA;
  void main() {
    if (vK <= 0.0 || vSide > vK) discard;
    float head = vK < 1.0 ? (1.0 - smoothstep(0.0, 0.12, vK - vSide)) : 0.0;
    gl_FragColor = vec4(uColor, min(1.0, vA * uFade + head * 0.7));
  }`;

export default function Globe3D({ points = [], recent = [], cells = [], ambient = false, onFocus, className = '', style }) {
  const host = useRef(null);
  const api = useRef(null);
  const data = useRef({ points, recent, cells });
  const focusCb = useRef(onFocus);
  focusCb.current = onFocus;

  // ---------------------------------------------------------------- scene (once)
  useEffect(() => {
    const el = host.current;
    if (!el) return undefined;
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'low-power' });
    } catch {
      return undefined;                                   // no WebGL: the page still works without the globe
    }
    const reduced = !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    const pixel = Math.min(window.devicePixelRatio || 1, 2);
    renderer.setPixelRatio(pixel);
    renderer.setClearColor(0x000000, 0);
    const canvas = renderer.domElement;
    canvas.style.display = 'block';
    canvas.style.touchAction = 'pan-y';
    el.appendChild(canvas);
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:absolute;inset:0;pointer-events:none;overflow:hidden';
    el.appendChild(overlay);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(40, 1, 0.005, 60);
    const mats = new Set();
    const track = (m) => { mats.add(m); return m; };
    const basic = (Kind, color, opacity) => {
      const m = new Kind({ color, transparent: true, opacity, depthWrite: false });
      m.userData.base = opacity;
      return m;
    };
    const dotMat = ({ opacity = 1, max = 6, ring = false, pop = false, blend = P.blend }) => track(new THREE.ShaderMaterial({
      vertexShader: DOT_VERT, fragmentShader: DOT_FRAG, transparent: true, depthWrite: false, blending: blend,
      uniforms: { uOpacity: { value: opacity }, uPixel: { value: pixel }, uMax: { value: max }, uNow: { value: 0 },
        uPop: { value: pop ? 1 : 0 }, uRing: { value: ring ? 1 : 0 }, uFade: { value: 1 } },
    }));
    const edgeMat = (color) => track(new THREE.ShaderMaterial({
      vertexShader: EDGE_VERT, fragmentShader: EDGE_FRAG, transparent: true, depthWrite: false, blending: P.blend,
      uniforms: { uNow: { value: 0 }, uColor: { value: new THREE.Color(color) }, uFade: { value: 1 } },
    }));
    const pointsGeo = (list) => {                         // list of {p: Vector3, color, size, born}
      const g = new THREE.BufferGeometry();
      const pos = new Float32Array(list.length * 3); const col = new Float32Array(list.length * 3);
      const size = new Float32Array(list.length); const born = new Float32Array(list.length);
      const c = new THREE.Color();
      list.forEach((o, i) => { o.p.toArray(pos, i * 3); c.set(o.color).toArray(col, i * 3); size[i] = o.size; born[i] = o.born || 0; });
      g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
      g.setAttribute('color', new THREE.BufferAttribute(col, 3));
      g.setAttribute('size', new THREE.BufferAttribute(size, 1));
      g.setAttribute('born', new THREE.BufferAttribute(born, 1));
      return g;
    };
    const edgeGeo = (list) => {                           // list of {path, born, dur, alpha}
      const pos = []; const side = []; const born = []; const dur = []; const alpha = [];
      list.forEach((e) => {
        const n = e.path.length - 1;
        for (let k = 0; k < n; k++) {
          const a = e.path[k]; const b = e.path[k + 1];
          pos.push(a.x, a.y, a.z, b.x, b.y, b.z);
          side.push(k / n, (k + 1) / n); born.push(e.born, e.born); dur.push(e.dur, e.dur); alpha.push(e.alpha, e.alpha);
        }
      });
      const g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      g.setAttribute('side', new THREE.Float32BufferAttribute(side, 1));
      g.setAttribute('born', new THREE.Float32BufferAttribute(born, 1));
      g.setAttribute('dur', new THREE.Float32BufferAttribute(dur, 1));
      g.setAttribute('alpha', new THREE.Float32BufferAttribute(alpha, 1));
      return g;
    };
    const dispose = (g) => {
      g.traverse((o) => {
        o.geometry?.dispose?.();
        if (o.material) [].concat(o.material).forEach((m) => { mats.delete(m); m.dispose(); });   // textures stay in the cache
      });
      g.parent?.remove(g);
      (g.userData.labels || []).forEach((l) => l.el.remove());
    };
    const setFade = (g, f) => {
      g.traverse((o) => {
        if (!o.material) return;
        [].concat(o.material).forEach((m) => {
          if (m.uniforms?.uFade) m.uniforms.uFade.value = f;
          else if (m.userData.base !== undefined) m.opacity = m.userData.base * f;
        });
      });
      (g.userData.labels || []).forEach((l) => { l.fade = f; });
    };

    // ---- static layers
    const loader = new THREE.TextureLoader();
    loader.setCrossOrigin('anonymous');
    const prep = (tex) => {
      tex.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
      tex.generateMipmaps = true; tex.minFilter = THREE.LinearMipmapLinearFilter;
      return tex;
    };
    const earthMat = new THREE.ShaderMaterial({
      vertexShader: EARTH_VERT, fragmentShader: EARTH_FRAG,
      uniforms: { uMap: { value: null }, uReady: { value: 0 } },
    });
    const core = new THREE.Mesh(new THREE.SphereGeometry(1, 128, 96), earthMat);
    scene.add(core);
    const big = !ambient && Math.max(window.screen?.width || 0, window.screen?.height || 0) * pixel > 1400;
    let landObj = null; let alive = true;
    loader.load(`/globe/earth-${big ? '4k' : '2k'}.jpg`, (tex) => {
      if (!alive) { tex.dispose(); return; }
      earthMat.uniforms.uMap.value = prep(tex);
      const t0 = performance.now();
      const fadeIn = () => {
        const k = clamp01((performance.now() - t0) / 900);
        earthMat.uniforms.uReady.value = k;
        if (landObj) landObj.visible = k < 1;
        if (k < 1 && alive) requestAnimationFrame(fadeIn); else if (reduced || ambient) requestAnimationFrame(frame);
      };
      fadeIn();
    });
    const halo = new THREE.Mesh(new THREE.SphereGeometry(1.07, 64, 64), new THREE.ShaderMaterial({
      transparent: true, side: THREE.BackSide, depthWrite: false, blending: THREE.AdditiveBlending,
      uniforms: { uC: { value: new THREE.Color(P.halo) }, uS: { value: P.haloStrength } },
      vertexShader: 'varying vec3 vN; void main(){ vN = normalize(normalMatrix * normal); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }',
      fragmentShader: 'uniform vec3 uC; uniform float uS; varying vec3 vN; void main(){ float i = pow(max(0.0, 0.62 - dot(vN, vec3(0.0,0.0,1.0))), 3.0) * uS; gl_FragColor = vec4(uC, clamp(i, 0.0, 1.0)); }',
    }));
    scene.add(halo);

    const grid = [];
    for (let lat = -60; lat <= 60; lat += 30) for (let lng = -180; lng < 180; lng += 3) grid.push(vec(lat, lng, 1.001), vec(lat, lng + 3, 1.001));
    for (let lng = -180; lng < 180; lng += 30) for (let lat = -84; lat < 84; lat += 3) grid.push(vec(lat, lng, 1.001), vec(lat + 3, lng, 1.001));
    scene.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(grid), basic(THREE.LineBasicMaterial, P.grid, P.gridAlpha)));

    const land = AIRFIELD_SQUARES.split(';').map((p) => p.split(',').map(Number));
    landObj = new THREE.Points(pointsGeo(land.map(([la, lo]) => ({ p: vec(la + 0.5, lo + 0.5, 1.002), color: P.land, size: 3.2 }))),
      dotMat({ opacity: P.landAlpha, max: 4 }));
    scene.add(landObj);                                          // shown only until the satellite image has loaded

    const schools = new THREE.Group(); scene.add(schools);     // every school found (small dots)
    const trail = new THREE.Group(); scene.add(trail);         // links between squares visited
    let net = null; const fading = [];                         // the network on the current square

    // pulses (one Points object, positions moved every frame)
    const MAXP = 48;
    const pulseGeo = pointsGeo(Array.from({ length: MAXP }, () => ({ p: new THREE.Vector3(), color: P.pulse, size: 5 })));
    const pulseObj = new THREE.Points(pulseGeo, dotMat({ max: 7 }));
    pulseObj.frustumCulled = false;
    scene.add(pulseObj);
    let pulses = [];

    // ---- camera: a view {lat, lng, z} where z = 0 is the whole globe and 1 is zoomed into a square
    const view = { lat: 25, lng: -60, z: 0, alt: 0.11, tilt: 3.5 };
    let FAR = 3.3;
    let path = [];
    function tween(now) {
      if (!path.length) return true;
      const s = path[0];
      if (s.t0 == null) { s.t0 = now; s.from = { ...view }; }
      const k = clamp01((now - s.t0) / s.dur); const e = ease(k);
      const { to, from } = s;
      if (to.lat !== undefined) { view.lat = from.lat + (to.lat - from.lat) * e; view.lng = from.lng + wrap(to.lng - from.lng) * e; }
      if (to.z !== undefined) view.z = from.z + (to.z - from.z) * e;
      if (to.alt !== undefined) { view.alt = from.alt + (to.alt - from.alt) * e; view.tilt = from.tilt + (to.tilt - from.tilt) * e; }
      if (s.dip) view.z = from.z + (1 - from.z) * e - Math.sin(Math.PI * k) * s.dip;
      if (k >= 1) path.shift();
      return !path.length;
    }
    const tmp = new THREE.Vector3(); const up = new THREE.Vector3();
    function applyCamera() {
      const z = clamp01(view.z);
      const T = vec(view.lat, view.lng, 1);
      const north = vec(Math.min(89, view.lat + 0.5), view.lng, 1).sub(T).normalize();
      const alt = view.alt * ((FAR - 1) / view.alt) ** (1 - z);        // exponential zoom feels like a real camera
      camera.position.copy(vec(view.lat - z * view.tilt, view.lng, 1 + alt));
      camera.up.copy(up.set(0, 1, 0).lerp(north, z).normalize());
      camera.lookAt(tmp.copy(T).multiplyScalar(z));
      camera.updateMatrixWorld();
      halo.material.uniforms.uS.value = P.haloStrength * clamp01(1 - z * 1.8);
    }

    // ---- labels (school names next to their nodes)
    const makeLabel = (r, color, born) => {
      const lab = document.createElement('div');
      lab.style.cssText = `position:absolute;left:0;top:0;display:flex;align-items:center;gap:6px;white-space:nowrap;opacity:0;
        font:600 11px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.02em;will-change:transform,opacity;`;
      const tag = document.createElement('span');
      tag.style.cssText = `background:rgba(2,6,23,.78);color:#f8fafc;border:1px solid rgba(165,243,252,.35);border-left:3px solid ${color};
        padding:3px 7px;border-radius:4px;backdrop-filter:blur(3px);box-shadow:0 0 12px rgba(34,211,238,.25)`;
      const nm = String(r.name || '').toUpperCase();
      tag.textContent = nm.length > 30 ? `${nm.slice(0, 29)}…` : nm;
      if (r.is_new) {
        const chip = document.createElement('b');
        chip.textContent = ' NEW';
        chip.style.cssText = 'color:#4ade80;font-weight:700';
        tag.appendChild(chip);
      }
      lab.appendChild(tag);
      overlay.appendChild(lab);
      return { el: lab, pos: vec(Number(r.lat), Number(r.lng), 1.006), born, fade: 1 };
    };

    // ---- sharp satellite close-up around a square (Landsat, NASA GIBS), cached
    const patches = new Map();
    // two layers per square: a wide one (fills the whole view) and a close one (extra sharp around the square)
    function patchBox(cell, wide = false) {
      const span = Math.max(0.05, cell.lat1 - cell.lat0);
      const cLat = (cell.lat0 + cell.lat1) / 2; const cLng = cell.lng0 + wrap(cell.lng1 - cell.lng0) / 2;
      const half = span / 2 + (wide ? Math.max(5, span * 6) : Math.max(1.4, span * 2.2));
      const halfLng = half / Math.max(0.35, Math.cos(cLat * DEG));
      const box = [Math.max(-85, cLat - half), cLng - halfLng, Math.min(85, cLat + half), cLng + halfLng];
      if (box[1] < -180 || box[3] > 180) return null;           // skip the date line
      return box.map((x) => Math.round(x * 1000) / 1000);
    }
    function getPatch(box) {
      const key = box.join(',');
      if (!patches.has(key)) {
        patches.set(key, new Promise((resolve) => {
          loader.load(`${GIBS}&BBOX=${box[1]},${box[0]},${box[3]},${box[2]}&WIDTH=1024&HEIGHT=1024`,
            (tex) => resolve(alive ? prep(tex) : (tex.dispose(), null)), undefined, () => resolve(null));
        }));
        if (patches.size > 8) {
          const [oldKey, oldP] = patches.entries().next().value;
          patches.delete(oldKey);
          setTimeout(() => oldP.then((t) => t?.dispose()), 4000);
        }
      }
      return patches.get(key);
    }
    function patchMesh(box, tex, wide) {
      const [la0, lo0, la1, lo1] = box; const n = wide ? 64 : 40;
      const pos = []; const nor = []; const uv = []; const idx = [];
      for (let j = 0; j <= n; j++) {
        for (let i = 0; i <= n; i++) {
          const v = vec(la0 + ((la1 - la0) * j) / n, lo0 + ((lo1 - lo0) * i) / n, wide ? 1.0003 : 1.0006);
          pos.push(v.x, v.y, v.z); v.normalize(); nor.push(v.x, v.y, v.z); uv.push(i / n, j / n);
        }
      }
      for (let j = 0; j < n; j++) {
        for (let i = 0; i < n; i++) {
          const a = j * (n + 1) + i; const b = a + 1; const c = a + n + 1; const d = c + 1;
          idx.push(a, c, b, b, c, d);
        }
      }
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      geo.setAttribute('normal', new THREE.Float32BufferAttribute(nor, 3));
      geo.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
      geo.setIndex(idx);
      const m = new THREE.Mesh(geo, new THREE.ShaderMaterial({
        vertexShader: EARTH_VERT, fragmentShader: PATCH_FRAG, transparent: true, depthWrite: false, side: THREE.DoubleSide,
        uniforms: { uMap: { value: tex }, uBase: { value: earthMat.uniforms.uMap.value || tex }, uBox: { value: new THREE.Vector4(la0, lo0, la1, lo1) }, uFade: { value: 0 } },
      }));
      m.renderOrder = wide ? -2 : -1;
      m.userData.keepTexture = true;
      return m;
    }

    // ---- one square: scan line, brackets, nodes, neural links, pulses, names
    function buildVisit(cell, t0, instant = false) {
      const g = new THREE.Group();
      const { lat0, lng0, lat1, lng1 } = cell;
      const span = Math.max(0.05, lat1 - lat0);
      const cLat = (lat0 + lat1) / 2; const cLng = lng0 + wrap(lng1 - lng0) / 2;
      const pad = Math.max(1.2, span * 1.6);
      const cos = Math.cos(cLat * DEG);
      const at = (x) => (instant ? -1e6 : x);
      const pts = (data.current.points || []).map(([la, lo, e]) => {
        const dLng = wrap(lo - cLng);
        return { la, lo, e, dLng,
          inCell: la >= lat0 && la <= lat1 && dLng >= -span / 2 && dLng <= span / 2,
          d: (la - cLat) ** 2 + (dLng * cos) ** 2 };
      }).filter((p) => Math.abs(p.la - cLat) <= span / 2 + pad && Math.abs(p.dLng) <= span / 2 + pad)
        .sort((a, b) => (b.inCell - a.inCell) || a.d - b.d).slice(0, 90);
      let ring = 0;
      pts.forEach((p) => {
        p.born = p.inCell ? t0 + SCAN * clamp01((p.la - lat0) / span) : t0 + SCAN + 0.3 + (ring++) * 0.035;
        p.v = vec(p.la, p.lo, 1.005);
      });
      const inCell = pts.filter((p) => p.inCell).length;

      // fine sector grid
      const step = span / 4; const half = span / 2 + pad; const fine = [];
      for (let la = Math.floor((cLat - half) / step) * step; la <= cLat + half; la += step) {
        for (let lo = -half; lo < half; lo += step / 2) fine.push(vec(la, cLng + lo, 1.0015), vec(la, cLng + lo + step / 2, 1.0015));
      }
      for (let lo = Math.floor((cLng - half) / step) * step; lo <= cLng + half; lo += step) {
        for (let la = cLat - half; la < cLat + half; la += step / 2) fine.push(vec(la, lo, 1.0015), vec(la + step / 2, lo, 1.0015));
      }
      g.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(fine), basic(THREE.LineBasicMaterial, P.fine, P.fineAlpha)));

      // square outline
      const edge = []; const n = 16;
      for (let i = 0; i <= n; i++) edge.push(vec(lat0, lng0 + ((lng1 - lng0) * i) / n, 1.003));
      for (let i = 0; i <= n; i++) edge.push(vec(lat0 + ((lat1 - lat0) * i) / n, lng1, 1.003));
      for (let i = n; i >= 0; i--) edge.push(vec(lat1, lng0 + ((lng1 - lng0) * i) / n, 1.003));
      for (let i = n; i >= 0; i--) edge.push(vec(lat0 + ((lat1 - lat0) * i) / n, lng0, 1.003));
      g.add(new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(edge), basic(THREE.LineBasicMaterial, P.scan, 0.85)));

      // lock-on brackets and scan line (moved every frame)
      const brackets = new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(Array.from({ length: 16 }, () => new THREE.Vector3())),
        basic(THREE.LineBasicMaterial, P.scan, 1));
      brackets.frustumCulled = false; g.add(brackets);
      const scanLine = new THREE.Line(new THREE.BufferGeometry().setFromPoints(Array.from({ length: 17 }, () => new THREE.Vector3())),
        basic(THREE.LineBasicMaterial, P.scan, 0.9));
      scanLine.frustumCulled = false; g.add(scanLine);

      // nodes: the probe at the square's centre, and every school around it
      const nodeList = [{ p: vec(cLat, cLng, 1.006), color: P.scan, size: 9, born: at(t0) },
        ...pts.map((p) => ({ p: p.v, color: P.school[p.e] || P.school[0], size: p.inCell ? 8 : 6, born: at(p.born) }))];
      g.add(new THREE.Points(pointsGeo(nodeList), dotMat({ max: 13, ring: true, pop: true })));

      // links: each school to its 3 nearest neighbours; the probe to every school inside the square
      const links = []; const probes = []; const seen = new Set();
      pts.forEach((p, i) => {
        pts.map((q, j) => [j, (p.la - q.la) ** 2 + ((p.lo - q.lo) * cos) ** 2]).filter(([j]) => j !== i)
          .sort((a, b) => a[1] - b[1]).slice(0, 3).forEach(([j, d2]) => {
            const key = i < j ? `${i}-${j}` : `${j}-${i}`;
            if (seen.has(key) || d2 > (span * 1.6) ** 2) return;
            seen.add(key);
            const q = pts[j];
            links.push({ path: arcPath(p.la, p.lo, q.la, q.lo, 1.005, 0.35, 8), born: at(Math.max(p.born, q.born) + 0.12), dur: 0.5, alpha: p.inCell || q.inCell ? 0.75 : 0.4 });
          });
        if (p.inCell) probes.push({ path: arcPath(cLat, cLng, p.la, p.lo, 1.006, 0.5, 10), born: at(p.born - 0.05), dur: 0.35, alpha: 0.55 });
      });
      if (links.length) g.add(new THREE.LineSegments(edgeGeo(links), edgeMat(P.edge)));
      if (probes.length) g.add(new THREE.LineSegments(edgeGeo(probes), edgeMat(P.probe)));

      // pulses along a handful of links
      const pl = [...probes.slice(0, 14), ...links.filter((l) => l.alpha > 0.5).slice(0, 20)].slice(0, MAXP - 4);
      const newPulses = pl.map((l, i) => ({ path: l.path, born: l.born + l.dur + (i % 5) * 0.4, dur: 0.9 + (i % 3) * 0.35, loop: true }));

      // names of the schools found in this square
      const named = (data.current.recent || []).filter((r) => (r.cell_id != null ? r.cell_id === cell.id
        : Number(r.lat) >= lat0 && Number(r.lat) <= lat1 && Number(r.lng) >= lng0 && Number(r.lng) <= lng1))
        .sort((a, b) => (b.is_new - a.is_new)).slice(0, 4);
      g.userData.labels = named.map((r, i) => makeLabel(r, r.eligibility === 'eligible_verified' ? P.school[2]
        : r.eligibility === 'eligible_claimed' ? P.school[1] : P.school[0], at(t0 + SCAN + 0.6 + i * 0.55)));

      g.userData.patches = [];
      [true, false].forEach((wide) => {
        const box = patchBox(cell, wide);
        if (!box) return;
        getPatch(box).then((tex) => {
          if (!tex || !alive || !g.parent) return;
          const m = patchMesh(box, tex, wide);
          m.userData.born = performance.now() / 1000;
          g.userData.patches.push(m);
          g.add(m);
          if (reduced) { m.material.uniforms.uFade.value = 1; requestAnimationFrame(frame); }
        });
      });

      Object.assign(g.userData, { cell, t0, lat0, lng0, lat1, lng1, span, cLat, cLng, brackets, scanLine, instant, inCell });
      scene.add(g);
      return { g, pulses: newPulses, inCell };
    }

    function animateVisit(g, t) {
      const u = g.userData;
      (u.patches || []).forEach((m) => { m.material.uniforms.uFade.value = clamp01((t - m.userData.born) / 0.9); });
      const k = u.instant ? 2 : (t - u.t0) / SCAN;
      // scan line, south to north, once
      const sl = u.scanLine;
      sl.visible = k >= 0 && k <= 1;
      if (sl.visible) {
        const la = u.lat0 + (u.lat1 - u.lat0) * k; const ext = u.span * 0.25;
        const arr = sl.geometry.attributes.position;
        for (let i = 0; i <= 16; i++) vec(la, u.lng0 - ext + ((u.lng1 - u.lng0 + 2 * ext) * i) / 16, 1.004).toArray(arr.array, i * 3);
        arr.needsUpdate = true;
      }
      // brackets close in on the square
      const s = 1 + 2.2 * (1 - ease(clamp01(u.instant ? 1 : (t - u.t0) / 0.7)));
      const h = (u.span / 2) * 1.22 * s; const leg = u.span * 0.28;
      const arr = u.brackets.geometry.attributes.position; let o = 0;
      [[-1, -1], [-1, 1], [1, -1], [1, 1]].forEach(([sy, sx]) => {
        const la = u.cLat + sy * h; const lo = u.cLng + sx * h;
        vec(la, lo, 1.004).toArray(arr.array, o); vec(la - sy * leg, lo, 1.004).toArray(arr.array, o + 3);
        vec(la, lo, 1.004).toArray(arr.array, o + 6); vec(la, lo - sx * leg, 1.004).toArray(arr.array, o + 9);
        o += 12;
      });
      arr.needsUpdate = true;
    }

    // ---- links between the squares visited (the "interlinking" trail)
    const trailLinks = [];
    function addTrail(from, to, t0, dur) {
      const d = angDist(from, to);
      trailLinks.push({ path: arcPath(from.lat, from.lng, to.lat, to.lng, 1.006, d > 10 ? 0.38 : 0.6, d > 10 ? 64 : 20), born: t0, dur, hub: to });
      while (trailLinks.length > 12) trailLinks.shift();
      trail.children.slice().forEach(dispose);
      const n = trailLinks.length;
      trail.add(new THREE.LineSegments(edgeGeo(trailLinks.map((l, i) => ({ ...l, alpha: 0.2 + (0.6 * (i + 1)) / n }))), edgeMat(P.link)));
      trail.add(new THREE.Points(pointsGeo(trailLinks.map((l) => ({ p: vec(l.hub.lat, l.hub.lng, 1.006), color: P.link, size: 6, born: l.born + l.dur }))),
        dotMat({ max: 9, ring: true, pop: true })));
      return trailLinks[trailLinks.length - 1].path;
    }

    // ---- the tour
    const dir = { phase: 'start', cur: null, t0: 0, lastLive: null, userUntil: 0, emitted: '' };
    const emit = (phase, extra = {}) => {
      const key = `${phase}:${dir.cur?.id ?? ''}`;
      if (key === dir.emitted) return;
      dir.emitted = key;
      const cs = data.current.cells || [];
      const idx = dir.cur ? cs.findIndex((c) => c.id === dir.cur.id) : -1;
      focusCb.current?.({ phase, cell: dir.cur, idx, total: cs.length, live: !!dir.cur && idx === cs.length - 1, ...extra });
    };
    const centre = (c) => ({ lat: (c.lat0 + c.lat1) / 2, lng: c.lng0 + wrap(c.lng1 - c.lng0) / 2 });

    function startVisit(cell, now) {
      const tgt = centre(cell);
      const span = Math.max(0.05, cell.lat1 - cell.lat0);
      const alt = 0.035 + span * 0.075; const tilt = span * 3.4;
      const d = angDist(view, tgt);
      const segs = []; let far = false;
      if (view.z < 0.4) {
        segs.push({ to: { lat: tgt.lat, lng: tgt.lng }, dur: 1 + d / 120 });
        segs.push({ to: { z: 1, alt, tilt }, dur: 1.8 });
      } else if (d <= 10) {
        segs.push({ to: { lat: tgt.lat, lng: tgt.lng, alt, tilt }, dur: 1.3 + d * 0.12, dip: 0.12 + d * 0.025 });
      } else {
        far = true;
        segs.push({ to: { z: 0 }, dur: 1.4 });
        segs.push({ to: { lat: tgt.lat, lng: tgt.lng }, dur: 1.1 + d / 100 });
        segs.push({ to: { z: 1, alt, tilt }, dur: 1.8 });
      }
      const total = segs.reduce((a, s) => a + s.dur, 0);
      path = segs;
      if (dir.cur) {
        const from = centre(dir.cur);
        const arcp = addTrail(from, tgt, now + (far ? 1.2 : 0), far ? total - 2.8 : total);
        pulses = pulses.filter((p) => p.trail).slice(-3);
        pulses.push({ path: arcp, born: now + (far ? 1.2 : 0), dur: far ? total - 2.8 : total, loop: false, trail: true });
      }
      if (net) { fading.push({ g: net.g, t0: now }); net = null; }
      dir.cur = cell; dir.phase = 'travel'; dir.t0 = now;
      emit('travel', { far });
    }

    function arrive(now) {
      net = buildVisit(dir.cur, now);
      pulses = [...pulses.filter((p) => p.trail && now - p.born < p.dur), ...net.pulses];
      dir.phase = 'scan'; dir.t0 = now;
      emit('scan', { inCell: net.inCell });
    }

    function nextCell() {
      const cs = data.current.cells || [];
      if (!cs.length) return null;
      const live = cs[cs.length - 1];
      if (dir.lastLive !== live.id) { dir.lastLive = live.id; return live; }        // a new square was searched: go there
      const i = dir.cur ? cs.findIndex((c) => c.id === dir.cur.id) : -1;
      if (i === cs.length - 1) return 'overview';
      return cs[i + 1] || cs[0];
    }

    function director(now) {
      if (now < dir.userUntil) { emit('manual'); return; }
      if (dir.phase === 'travel') { if (tween(now)) arrive(now); return; }
      if (dir.phase === 'overview') {
        tween(now);
        view.lng -= 0.1; if (view.lat > 18) view.lat -= 0.05; else if (view.lat < 12) view.lat += 0.05;
        if (now - dir.t0 < OVERVIEW) return;
      }
      if (dir.phase === 'scan' && now - dir.t0 >= SCAN) {
        dir.phase = 'lock'; emit('lock', { inCell: net?.inCell });
        const cs = data.current.cells || []; const i = cs.findIndex((c) => c.id === dir.cur?.id);
        const peek = cs[i + 1] || cs[0];
        [true, false].forEach((w) => { const pb = peek && patchBox(peek, w); if (pb) getPatch(pb); });   // fetch the next close-up while we wait
      }
      if ((dir.phase === 'scan' || dir.phase === 'lock') && now - dir.t0 < DWELL) return;
      const nx = nextCell();
      if (!nx) { if (dir.phase !== 'overview') { dir.phase = 'overview'; dir.t0 = now; path = [{ to: { z: 0 }, dur: 1.4 }]; emit('overview'); } return; }
      if (nx === 'overview') {
        if (net) { fading.push({ g: net.g, t0: now }); net = null; }
        dir.phase = 'overview'; dir.t0 = now; path = [{ to: { z: 0 }, dur: 1.6 }]; pulses = [];
        const cs = data.current.cells || [];
        dir.cur = cs[cs.length - 1] || dir.cur;
        emit('overview');
        dir.cur = null;                                  // the next round starts from the oldest square
        dir.lastLive = cs[cs.length - 1]?.id ?? dir.lastLive;
        dir.restart = true;
        return;
      }
      if (dir.restart) { dir.restart = false; const cs = data.current.cells || []; startVisit(cs[0] || nx, now); return; }
      startVisit(nx, now);
    }

    // ---- drag to look around
    let drag = null;
    const down = (e) => { drag = { x: e.clientX, y: e.clientY, lat: view.lat, lng: view.lng }; path = []; dir.userUntil = Infinity; };
    const move = (e) => {
      if (!drag) return;
      const alt = view.alt * ((FAR - 1) / view.alt) ** (1 - clamp01(view.z));
      const k = 0.13 * alt * (60 / Math.max(240, el.clientHeight)) * 4;
      view.lng = drag.lng - (e.clientX - drag.x) * k;
      view.lat = Math.max(-75, Math.min(75, drag.lat + (e.clientY - drag.y) * k));
    };
    const upH = () => {
      if (!drag) return;
      drag = null;
      dir.userUntil = performance.now() / 1000 + 10;
      if (dir.phase === 'travel') dir.phase = 'lock';      // abandon the half-finished flight; the tour resumes from here
      dir.t0 = -1e9; dir.emitted = '';
    };
    if (!ambient) {
      canvas.addEventListener('pointerdown', down);
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', upH);
      window.addEventListener('pointercancel', upH);
      canvas.style.cursor = 'grab';
    }

    const resize = () => {
      const w = el.clientWidth || 1; const h = el.clientHeight || 1;
      renderer.setSize(w, h, false);
      canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
      camera.aspect = w / h; camera.updateProjectionMatrix();
      const halfV = 20 * DEG; const halfH = Math.atan(Math.tan(halfV) * camera.aspect);
      FAR = (ambient ? 1.02 : 1.14) / Math.sin(Math.min(halfV, halfH));   // whole globe fits, with a margin
    };
    const ro = new ResizeObserver(resize); ro.observe(el); resize();

    // ---- frame loop
    let visible = true; let raf = 0;
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) loop(); }, { threshold: 0 });
    io.observe(el);
    const onVis = () => { if (!document.hidden) loop(); };
    document.addEventListener('visibilitychange', onVis);
    const sp = new THREE.Vector3(); const cdir = new THREE.Vector3();

    function frame(nowMs) {
      const t = nowMs / 1000;
      if (ambient) { view.lng -= 0.06; view.lat = 18; view.z = 0; }
      else if (!reduced && !drag) director(t);
      applyCamera();
      mats.forEach((m) => { if (m.uniforms?.uNow) m.uniforms.uNow.value = reduced ? 1e6 : t; });

      if (net) animateVisit(net.g, t);
      for (let i = fading.length - 1; i >= 0; i--) {
        const f = fading[i]; const k = clamp01((t - f.t0) / 0.7);
        setFade(f.g, 1 - k);
        if (k >= 1) { dispose(f.g); fading.splice(i, 1); }
      }

      // pulses
      const arr = pulseGeo.attributes.position;
      for (let i = 0; i < MAXP; i++) {
        const p = pulses[i];
        let k = p ? (t - p.born) / p.dur : -1;
        if (p && p.loop && k >= 0) k %= 1;
        if (!p || k < 0 || k > 1 || reduced) { arr.array[i * 3] = 0; arr.array[i * 3 + 1] = 0; arr.array[i * 3 + 2] = 0; continue; }
        const f = k * (p.path.length - 1); const j = Math.floor(f);
        sp.copy(p.path[j]).lerp(p.path[Math.min(j + 1, p.path.length - 1)], f - j).toArray(arr.array, i * 3);
      }
      arr.needsUpdate = true;

      // labels
      const w = el.clientWidth; const h = el.clientHeight;
      const labels = [...(net?.g.userData.labels || []), ...fading.flatMap((f) => f.g.userData.labels || [])];
      const placed = [];
      labels.map((l) => {
        sp.copy(l.pos).project(camera);
        const facing = cdir.copy(camera.position).sub(l.pos).normalize().dot(tmp.copy(l.pos).normalize());
        return { l, on: sp.z < 1 && facing > 0.15 && Math.abs(sp.x) < 1.05 && Math.abs(sp.y) < 1.05,
          x: (sp.x * 0.5 + 0.5) * w, y: (-sp.y * 0.5 + 0.5) * h };
      }).sort((a, b) => a.y - b.y).forEach(({ l, on, x, y }) => {
        if (on && !l.wd) l.wd = l.el.offsetWidth;        // measured once; flip to the left if the name would run off the edge
        const left = x + 10 + (l.wd || 160) > w - 6 && x - 10 - (l.wd || 160) > 6;
        let ly = y;                                       // keep names from sitting on top of each other
        placed.forEach((q) => { if (q.left === left && Math.abs(q.x - x) < 190 && ly - q.y < 22) ly = q.y + 22; });
        if (on) placed.push({ x, y: ly, left });
        l.el.style.transform = `translate(${Math.round(x)}px, ${Math.round(ly)}px) translate(${left ? 'calc(-100% - 10px)' : '10px'}, -50%)`;
        l.el.style.opacity = on ? String(clamp01((reduced ? 1 : (t - l.born) / 0.4)) * l.fade) : '0';
      });

      renderer.render(scene, camera);
    }
    function loop() {
      cancelAnimationFrame(raf);
      const tick = (now) => {
        if (!visible || document.hidden) return;
        frame(now);
        if (!reduced) raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
    }

    // ---- data updates from React
    api.current = {
      setData() {
        schools.children.slice().forEach(dispose);
        const pts = data.current.points || [];
        if (pts.length) {
          schools.add(new THREE.Points(pointsGeo(pts.map(([la, lo, e]) => ({ p: vec(la, lo, 1.004), color: P.school[e] || P.school[0], size: e === 2 ? 3.6 : 2.8 }))),
            dotMat({ max: 5, opacity: 0.85, blend: THREE.NormalBlending })));
        }
        if (reduced && !ambient) {                     // still picture of the newest square
          const cs = data.current.cells || [];
          const live = cs[cs.length - 1];
          if (live && dir.cur?.id !== live.id) {
            if (net) dispose(net.g);
            const c = centre(live); const span = Math.max(0.05, live.lat1 - live.lat0);
            Object.assign(view, { lat: c.lat, lng: c.lng, z: 1, alt: 0.035 + span * 0.075, tilt: span * 3.4 });
            dir.cur = live; net = buildVisit(live, 0, true);
            emit('lock', { inCell: net.inCell });
          }
        }
        if (reduced || ambient) requestAnimationFrame(frame);
      },
    };
    api.current.setData();
    loop();

    return () => {
      alive = false; cancelAnimationFrame(raf); ro.disconnect(); io.disconnect();
      document.removeEventListener('visibilitychange', onVis);
      canvas.removeEventListener('pointerdown', down);
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', upH);
      window.removeEventListener('pointercancel', upH);
      [net?.g, ...fading.map((f) => f.g)].filter(Boolean).forEach(dispose);
      scene.traverse((o) => { o.geometry?.dispose?.(); if (o.material) [].concat(o.material).forEach((m) => m.dispose()); });
      patches.forEach((pr) => pr.then((t) => t?.dispose()));
      earthMat.uniforms.uMap.value?.dispose();
      renderer.dispose(); canvas.remove(); overlay.remove(); api.current = null;
    };
  }, [ambient]);

  // ---------------------------------------------------------------- data
  useEffect(() => {
    data.current = { points, recent, cells };
    api.current?.setData();
  }, [points, recent, cells]);

  return <div ref={host} className={className} style={{ position: 'relative', width: '100%', height: '100%', ...style }} aria-hidden="true" />;
}
