/** @type {import('tailwindcss').Config} */
// Wire in liquidglass-tailwind's *theme tokens only* (additive, non-colliding):
// this exposes bg-glass-*, border-glass-border-*, rounded-glass-*, and
// shadow-glass-* across the app. We intentionally do NOT register the full
// plugin — its component classes (.glass-card/.glass-btn/.glass-nav/…) collide
// with our hand-tuned light-mode system in src/index.css.
import { liquidGlassTheme } from 'liquidglass-tailwind/theme';

// ── Apple system colours (Human Interface Guidelines, light mode) ──────────────
// Every Tailwind colour family used in the CRM is mapped onto an Apple system colour, so existing classes
// like `bg-blue-600` or `text-red-700` pick up Apple's palette without touching component logic.
//   500 = the system colour itself (fills, dots, bars)
//   600+ = Apple's "increased contrast" variant and darker steps, so coloured TEXT stays readable on white
//   50–400 = soft tints of the system colour (badges, backgrounds)
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const toHex = (rgb) => `#${rgb.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('')}`.toUpperCase();
const mix = (a, b, t) => toHex(hex(a).map((v, i) => v + (hex(b)[i] - v) * t));
function scale(base, strong) {
  return {
    50: mix(base, '#FFFFFF', 0.92), 100: mix(base, '#FFFFFF', 0.85), 200: mix(base, '#FFFFFF', 0.7),
    300: mix(base, '#FFFFFF', 0.5), 400: mix(base, '#FFFFFF', 0.25), 500: base, 600: strong,
    700: mix(strong, '#000000', 0.15), 800: mix(strong, '#000000', 0.32), 900: mix(strong, '#000000', 0.5), 950: mix(strong, '#000000', 0.65),
  };
}
// Apple light-mode system colour and its increased-contrast variant
const blue = { ...scale('#007AFF', '#0062CC'), 600: '#007AFF', 700: '#0062CC' };   // buttons stay the classic #007AFF
const indigo = { ...scale('#5856D6', '#3634A3'), 600: '#5856D6', 700: '#3634A3' };
const red = scale('#FF3B30', '#D70015');
const green = scale('#34C759', '#248A3D');
const orange = scale('#FF9500', '#C93400');
const yellow = scale('#FFCC00', '#A05A00');
const teal = scale('#30B0C7', '#008299');
const cyan = scale('#32ADE6', '#0071A4');
const purple = scale('#AF52DE', '#8944AB');
const pink = scale('#FF2D55', '#D30F45');
// Apple greys: systemGray6 … systemGray, then the label greys for text
const gray = {
  50: '#F9F9FB', 100: '#F2F2F7', 200: '#E5E5EA', 300: '#D1D1D6', 400: '#AEAEB2', 500: '#6C6C70',
  600: '#545458', 700: '#3A3A3C', 800: '#2C2C2E', 900: '#1C1C1E', 950: '#000000',
};

export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      ...liquidGlassTheme,
      colors: {
        ...(liquidGlassTheme.colors || {}),
        gray, slate: gray, zinc: gray, neutral: gray, stone: gray,
        blue, sky: cyan, indigo, violet: indigo, purple, fuchsia: purple,
        red, rose: pink, pink, orange, amber: orange, yellow,
        green, emerald: green, lime: green, teal, cyan,
      },
      borderRadius: { ...(liquidGlassTheme.borderRadius || {}), xl: '14px', '2xl': '18px', '3xl': '26px' },
    },
  },
  plugins: [],
}
