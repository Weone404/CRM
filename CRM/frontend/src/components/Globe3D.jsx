import { useEffect, useRef } from 'react';
import * as THREE from 'three';
import { AIRFIELD_SQUARES } from '../data/airfields';

// Live 3D globe for the FlightBridge School Detector (and, quieter, behind the login screen).
// Dotted Earth = every map square with an airfield (the squares the world sweep searches); bright dots = schools
// found (green eligible, amber check needed, cyan other); "neural" arcs link each new find to its nearest
// neighbours with pulses running along them; the square being scanned glows with a beam and ripples.
// Plain three.js, no extra libraries. Pauses when off-screen or the tab is hidden; respects reduced motion.

const DEG = Math.PI / 180;
const COLORS = { 2: new THREE.Color('#34d399'), 1: new THREE.Color('#fbbf24'), 0: new THREE.Color('#22d3ee') };

function vec(lat, lng, r = 1) {
  const phi = (90 - lat) * DEG;
  const theta = (lng + 180) * DEG;
  return new THREE.Vector3(-r * Math.sin(phi) * Math.cos(theta), r * Math.cos(phi), r * Math.sin(phi) * Math.sin(theta));
}

function arc(a, b, segments = 32) {
  // great-circle-ish curve lifted off the surface in proportion to distance
  const mid = a.clone().add(b).multiplyScalar(0.5);
  const lift = 1 + Math.min(0.35, a.distanceTo(b) * 0.45);
  mid.normalize().multiplyScalar(lift);
  return new THREE.QuadraticBezierCurve3(a, mid, b).getPoints(segments);
}

const DOT_VERT = `
  attribute float size; attribute vec3 color; varying vec3 vColor; varying float vFacing;
  uniform float uPixel;
  void main() {
    vColor = color;
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vec3 n = normalize(normalMatrix * normalize(position));
    vFacing = dot(n, normalize(-mv.xyz));
    gl_PointSize = size * uPixel * (2.6 / -mv.z);
    gl_Position = projectionMatrix * mv;
  }`;
const DOT_FRAG = `
  varying vec3 vColor; varying float vFacing; uniform float uOpacity;
  void main() {
    vec2 c = gl_PointCoord - 0.5; float d = length(c);
    if (d > 0.5) discard;
    float glow = smoothstep(0.5, 0.0, d);
    float side = smoothstep(-0.15, 0.25, vFacing);          // fade dots on the far side
    gl_FragColor = vec4(vColor, glow * uOpacity * (0.18 + 0.82 * side));
  }`;

function dotMaterial(opacity, pixel) {
  return new THREE.ShaderMaterial({
    vertexShader: DOT_VERT, fragmentShader: DOT_FRAG, transparent: true, depthWrite: false,
    blending: THREE.AdditiveBlending, uniforms: { uOpacity: { value: opacity }, uPixel: { value: pixel } },
  });
}

export default function Globe3D({ points = [], recent = [], scanning = null, ambient = false, className = '', style }) {
  const host = useRef(null);
  const api = useRef(null);

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
    const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    const pixel = Math.min(window.devicePixelRatio || 1, 1.75);
    renderer.setPixelRatio(pixel);
    renderer.setClearColor(0x000000, 0);
    el.appendChild(renderer.domElement);
    renderer.domElement.style.display = 'block';
    renderer.domElement.style.touchAction = 'pan-y';

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 50);
    camera.position.set(0, 0, ambient ? 3.1 : 3.35);
    const globe = new THREE.Group();
    globe.rotation.x = 0.35;
    scene.add(globe);

    // core + atmosphere
    globe.add(new THREE.Mesh(new THREE.SphereGeometry(0.985, 64, 64),
      new THREE.MeshBasicMaterial({ color: '#04101d', transparent: true, opacity: ambient ? 0.55 : 0.92 })));
    const atmo = new THREE.Mesh(new THREE.SphereGeometry(1.06, 64, 64), new THREE.ShaderMaterial({
      transparent: true, side: THREE.BackSide, blending: THREE.AdditiveBlending, depthWrite: false,
      vertexShader: 'varying vec3 vN; void main(){ vN = normalize(normalMatrix * normal); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }',
      fragmentShader: 'varying vec3 vN; void main(){ float i = pow(max(0.0, 0.62 - dot(vN, vec3(0.0,0.0,1.0))), 3.0); gl_FragColor = vec4(0.13,0.83,0.93,1.0) * i * 0.9; }',
    }));
    scene.add(atmo);

    // graticule
    const grid = [];
    for (let lat = -60; lat <= 60; lat += 30) for (let lng = -180; lng < 180; lng += 4) grid.push(vec(lat, lng, 1.001), vec(lat, lng + 4, 1.001));
    for (let lng = -180; lng < 180; lng += 30) for (let lat = -84; lat < 84; lat += 4) grid.push(vec(lat, lng, 1.001), vec(lat + 4, lng, 1.001));
    globe.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(grid),
      new THREE.LineBasicMaterial({ color: '#22d3ee', transparent: true, opacity: 0.1 })));

    // dotted Earth (airfield squares)
    const land = AIRFIELD_SQUARES.split(';').map((p) => p.split(',').map(Number));
    const lp = new Float32Array(land.length * 3); const lc = new Float32Array(land.length * 3); const ls = new Float32Array(land.length);
    const landColor = new THREE.Color(ambient ? '#2b8fb0' : '#2fa3c7');
    land.forEach(([la, lo], i) => {
      vec(la + 0.5, lo + 0.5, 1.003).toArray(lp, i * 3); landColor.toArray(lc, i * 3); ls[i] = 3.4;
    });
    const landGeo = new THREE.BufferGeometry();
    landGeo.setAttribute('position', new THREE.BufferAttribute(lp, 3));
    landGeo.setAttribute('color', new THREE.BufferAttribute(lc, 3));
    landGeo.setAttribute('size', new THREE.BufferAttribute(ls, 1));
    globe.add(new THREE.Points(landGeo, dotMaterial(ambient ? 0.7 : 0.8, pixel)));

    // layers filled from data (rebuilt on change)
    const dynamic = new THREE.Group(); globe.add(dynamic);
    const pulses = []; const pings = []; let beam = null;

    // drag to turn
    let drag = null; let spinVel = reduced ? 0 : 0.0016; let idleSince = 0;
    const down = (e) => { drag = { x: e.clientX, y: e.clientY, rx: globe.rotation.x, ry: globe.rotation.y }; };
    const move = (e) => {
      if (!drag) return;
      globe.rotation.y = drag.ry + (e.clientX - drag.x) * 0.006;
      globe.rotation.x = Math.max(-1.1, Math.min(1.1, drag.rx + (e.clientY - drag.y) * 0.004));
      idleSince = performance.now();
    };
    const up = () => { drag = null; };
    if (!ambient) {
      renderer.domElement.addEventListener('pointerdown', down);
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
      renderer.domElement.style.cursor = 'grab';
    }

    const resize = () => {
      const w = el.clientWidth || 1; const h = el.clientHeight || 1;
      renderer.setSize(w, h, false);
      renderer.domElement.style.width = `${w}px`; renderer.domElement.style.height = `${h}px`;
      camera.aspect = w / h; camera.updateProjectionMatrix();
    };
    const ro = new ResizeObserver(resize); ro.observe(el); resize();

    let visible = true; let raf = 0; let last = performance.now();
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) loop(); }, { threshold: 0 });
    io.observe(el);
    const onVis = () => { if (!document.hidden) loop(); };
    document.addEventListener('visibilitychange', onVis);

    function frame(now) {
      const dt = Math.min(64, now - last); last = now;
      const t = now / 1000;
      if (!drag && now - idleSince > 2500) globe.rotation.y += spinVel * dt * 0.06;
      if (!reduced) {
        pulses.forEach((p) => {
          p.t = (p.t + dt * p.speed) % 1;
          const i = Math.floor(p.t * (p.path.length - 1));
          p.mesh.position.copy(p.path[i]);
        });
        pings.forEach((p) => {
          const k = ((t + p.phase) % 2.2) / 2.2;
          p.mesh.scale.setScalar(0.2 + k * p.max);
          p.mesh.material.opacity = (1 - k) * 0.85;
        });
        if (beam) beam.material.opacity = 0.45 + Math.sin(t * 3) * 0.25;
      }
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
    loop();

    api.current = {
      reduced, dynamic, pulses, pings, globe, pixel,
      setBeam(b) { beam = b; },
      redraw: () => { if (reduced) requestAnimationFrame(frame); },
      focus(lat, lng) {                                   // turn the scanned square towards the viewer once
        if (reduced || drag) return;
        globe.rotation.y = -(lng + 90) * DEG; globe.rotation.x = Math.max(-0.9, Math.min(0.9, lat * DEG * 0.8));
      },
    };

    return () => {
      cancelAnimationFrame(raf); ro.disconnect(); io.disconnect();
      document.removeEventListener('visibilitychange', onVis);
      renderer.domElement.removeEventListener('pointerdown', down);
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up);
      scene.traverse((o) => { o.geometry?.dispose?.(); if (o.material) [].concat(o.material).forEach((m) => m.dispose()); });
      renderer.dispose(); renderer.domElement.remove(); api.current = null;
    };
  }, [ambient]);

  // ---------------------------------------------------------------- data layers
  const focused = useRef(false);
  useEffect(() => {
    const a = api.current;
    if (!a) return;
    const { dynamic, pulses, pings } = a;
    dynamic.children.slice().forEach((o) => { dynamic.remove(o); o.geometry?.dispose?.(); o.material?.dispose?.(); });
    pulses.length = 0; pings.length = 0; a.setBeam(null);

    // schools
    if (points.length) {
      const p = new Float32Array(points.length * 3); const c = new Float32Array(points.length * 3); const s = new Float32Array(points.length);
      points.forEach(([la, lo, e], i) => { vec(la, lo, 1.006).toArray(p, i * 3); (COLORS[e] || COLORS[0]).toArray(c, i * 3); s[i] = e === 2 ? 5.5 : 4.2; });
      const g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.BufferAttribute(p, 3)); g.setAttribute('color', new THREE.BufferAttribute(c, 3));
      g.setAttribute('size', new THREE.BufferAttribute(s, 1));
      dynamic.add(new THREE.Points(g, dotMaterial(1, a.pixel)));
    }

    // neural links: each recent find to its two nearest schools
    const pos = points.map(([la, lo]) => vec(la, lo, 1.006));
    const linkVerts = [];
    const seen = new Set();
    recent.slice(0, 24).forEach((d, idx) => {
      const v = vec(Number(d.lat), Number(d.lng), 1.006);
      const near = pos.map((q, i) => [q.distanceToSquared(v), i]).filter(([dd]) => dd > 1e-6 && dd < 0.09)
        .sort((x, y) => x[0] - y[0]).slice(0, 2);
      near.forEach(([, i]) => {
        const key = `${idx}-${i}`; if (seen.has(key)) return; seen.add(key);
        const path = arc(v, pos[i], 24);
        for (let k = 0; k < path.length - 1; k++) linkVerts.push(path[k], path[k + 1]);
        if (pulses.length < 30) {
          const m = new THREE.Mesh(new THREE.SphereGeometry(0.006, 6, 6), new THREE.MeshBasicMaterial({ color: '#a5f3fc' }));
          dynamic.add(m); pulses.push({ mesh: m, path, t: Math.random(), speed: 0.0004 + Math.random() * 0.0004 });
        }
      });
      if (idx < 8 && d.is_new) {                         // ripple on the newest finds
        const ring = new THREE.Mesh(new THREE.RingGeometry(0.018, 0.022, 32),
          new THREE.MeshBasicMaterial({ color: d.eligibility === 'eligible_verified' ? '#34d399' : '#22d3ee', transparent: true, side: THREE.DoubleSide, depthWrite: false }));
        ring.position.copy(vec(Number(d.lat), Number(d.lng), 1.008)); ring.lookAt(ring.position.clone().multiplyScalar(2));
        dynamic.add(ring); pings.push({ mesh: ring, phase: idx * 0.27, max: 2.2 });
      }
    });
    if (linkVerts.length) {
      dynamic.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(linkVerts),
        new THREE.LineBasicMaterial({ color: '#38bdf8', transparent: true, opacity: 0.35, blending: THREE.AdditiveBlending, depthWrite: false })));
    }

    // the square being scanned
    if (scanning && scanning.lat0 !== undefined) {
      const { lat0, lng0, lat1, lng1 } = scanning;
      const edge = [];
      const n = 12;
      for (let i = 0; i <= n; i++) edge.push(vec(lat0, lng0 + ((lng1 - lng0) * i) / n, 1.01));
      for (let i = 0; i <= n; i++) edge.push(vec(lat0 + ((lat1 - lat0) * i) / n, lng1, 1.01));
      for (let i = n; i >= 0; i--) edge.push(vec(lat1, lng0 + ((lng1 - lng0) * i) / n, 1.01));
      for (let i = n; i >= 0; i--) edge.push(vec(lat0 + ((lat1 - lat0) * i) / n, lng0, 1.01));
      dynamic.add(new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(edge), new THREE.LineBasicMaterial({ color: '#f472b6' })));
      const cLat = (lat0 + lat1) / 2; const cLng = (lng0 + lng1) / 2;
      const beamMesh = new THREE.Line(new THREE.BufferGeometry().setFromPoints([vec(cLat, cLng, 1.01), vec(cLat, cLng, 1.45)]),
        new THREE.LineBasicMaterial({ color: '#f472b6', transparent: true, opacity: 0.6 }));
      dynamic.add(beamMesh); a.setBeam(beamMesh);
      for (let k = 0; k < 3; k++) {
        const ring = new THREE.Mesh(new THREE.RingGeometry(0.03, 0.036, 48),
          new THREE.MeshBasicMaterial({ color: '#f472b6', transparent: true, side: THREE.DoubleSide, depthWrite: false }));
        ring.position.copy(vec(cLat, cLng, 1.009)); ring.lookAt(ring.position.clone().multiplyScalar(2));
        dynamic.add(ring); pings.push({ mesh: ring, phase: k * 0.73, max: 3.2 });
      }
      if (!focused.current) { a.focus(cLat, cLng); focused.current = true; }
    }
    a.redraw();
  }, [points, recent, scanning]);

  return <div ref={host} className={className} style={{ position: 'relative', width: '100%', height: '100%', ...style }} aria-hidden="true" />;
}
