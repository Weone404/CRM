// Instant "Generate with AI" ideas, made in the browser from the product's own facts (no paid AI, no network).
// Only facts already on the listing are used (size, colour, cover, pages, ruling, closure ...), so no claim is invented.
// Every idea is checked against the same limits the database guard uses (title 75 chars, a word at most twice,
// no sales words, hidden search words 249 bytes). Claude's ideas (asynchronous) come from api_amz_suggest instead.
import { utf8Bytes } from './amazon';

const v0 = (a, k) => {
  const x = a?.[k]?.[0];
  if (!x) return '';
  if (x.value != null && typeof x.value !== 'object') return String(x.value);
  return '';
};
const tidy = (s) => String(s || '').replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
const cap = (s) => tidy(s).replace(/\b([a-z])/g, (m) => m.toUpperCase());
const PROMO = /\b(best ?seller|#1|no\.? ?1|free|sale|offer|discount|cheapest|guaranteed)\b/i;

export function facts(l) {
  const a = l?.attributes || {};
  const text = `${l?.title || ''} ${(l?.bullets || []).join(' ')} ${l?.description || ''}`;
  // Diaries sell for the coming year: from September on, only next year's number is used; older years are dropped.
  const now = new Date();
  const minYear = now.getFullYear() + (now.getMonth() >= 8 ? 1 : 0);
  const found = Number((text.match(/\b(20[2-3]\d)\b/g) || []).sort().pop() || 0);
  const year = found >= minYear ? String(found) : '';
  const pages = a.pages?.[0]?.value ?? v0(a, 'page_count');
  const material = a.cover?.[0]?.material?.[0]?.value || v0(a, 'material') || (/leather/i.test(text) ? 'PU Leather' : '');
  return {
    brand: cap(v0(a, 'team_name') || (/nitaniya/i.test(text) ? 'Nitaniya' : '')),
    year,
    size: v0(a, 'paper_size') || v0(a, 'size') || ((text.match(/\b(A4|A5|A6|B5)\b/i) || [])[1] || '').toUpperCase(),
    color: cap(v0(a, 'color').split(/\s*-\s*/).filter((x, i, arr) => arr.findIndex((y) => y.toLowerCase() === x.toLowerCase()) === i).join(' ')),
    material: cap(material).replace(/^Faux Leather$/, 'Faux Leather'),
    pages: pages ? String(pages) : '',
    ruling: cap(v0(a, 'ruling_type')),
    closure: /button/i.test(v0(a, 'style') + text) ? 'Button Closure' : /magnet/i.test(text) ? 'Magnetic Closure' : /strap/i.test(text) ? 'Strap Closure' : '',
    penHolder: /pen holder|pen loop/i.test(text),
    ribbon: /ribbon/i.test(text),
    personal: /custom|personal|with name|your name/i.test(text),
    dated: /dated|with dates|daily planner|365 days/i.test(text),
  };
}

// A word may appear at most twice (plurals count as the same word), like the database rule.
export function wordRepeatOk(s, max = 2) {
  const n = {};
  for (const w of String(s).toLowerCase().match(/[a-z0-9]+/g) || []) {
    const k = w.length > 3 ? w.replace(/(es|s)$/, '') : w;
    if ((n[k] = (n[k] || 0) + 1) > max) return false;
  }
  return true;
}
const uniq = (arr) => [...new Set(arr.filter(Boolean))];

// Adds parts in order while the name stays within the limit, so nothing is cut mid-word.
function build(parts, max = 75) {
  let out = '';
  for (const p of parts.filter(Boolean)) {
    const next = out ? `${out}${p.startsWith(',') ? '' : ' '}${p}` : p.replace(/^[,|]\s*/, '');
    if ([...next].length <= max) out = next;
  }
  return tidy(out);
}

export function titleIdeas(l) {
  const f = facts(l);
  const nm = f.personal ? 'with Name' : '';
  const pg = f.pages ? `${f.pages} ${f.ruling ? `${f.ruling} ` : ''}Pages` : '';
  const list = [
    [f.brand, f.year, 'Personalised Diary', nm, f.size && `, ${f.size}`, f.material && `${f.material} Cover`, f.color && `, ${f.color}`],
    ['Customised', f.year, 'Diary', nm, f.size && `| ${f.size}`, pg && `, ${pg}`, f.color && `, ${f.color}`],
    [f.brand, f.size, f.material, 'Diary', f.year, f.personal && ', Personalised Name', pg && `, ${pg}`],
    [f.year && `${f.year}`, f.dated ? 'Dated Planner' : 'Diary', nm, 'for Men & Women', f.size && `, ${f.size}`, f.color],
    ['Personalised', f.size, 'Diary', f.year, nm, f.closure && `, ${f.closure}`, f.penHolder && ', Pen Holder', f.ribbon && ', Ribbon Bookmark'],
  ];
  return uniq(list.map((parts) => build(parts)))
    .filter((t) => t.length >= 25 && wordRepeatOk(t) && !PROMO.test(t)).slice(0, 5);
}

export function bulletIdeas(l) {
  const f = facts(l);
  const cover = [f.color, f.material].filter(Boolean).join(' ') || 'Durable';
  const pages = f.pages ? `${f.pages} ${f.ruling ? f.ruling.toLowerCase() : ''} pages`.replace(/\s+/g, ' ') : 'plenty of pages';
  const extras = [f.closure && f.closure.toLowerCase(), f.penHolder && 'pen holder', f.ribbon && 'ribbon bookmark'].filter(Boolean);
  const extrasText = extras.length ? extras.join(', ').replace(/, ([^,]*)$/, ' and $1') : '';
  const personal = f.personal;
  const sets = [
    [ // Feature first
      personal && 'PERSONALISED WITH YOUR NAME – Add a name or short text for the cover with the Customise button before you buy.',
      `PREMIUM COVER – ${cover} cover that looks smart at the office, at college and at home.`,
      `${f.size ? `${f.size} SIZE, ` : ''}${pages.toUpperCase()} – Room for daily notes, plans, meetings and to-do lists.`,
      extrasText && `PRACTICAL DETAILS – ${extrasText[0].toUpperCase()}${extrasText.slice(1)} keep your diary neat and easy to use.`,
      'THOUGHTFUL GIFT – A useful gift for New Year, birthdays, Diwali, teachers and corporate gifting.',
    ],
    [ // Gift first
      personal ? 'A GIFT WITH THEIR NAME – Personalise the cover with any name, so the diary feels made just for them.' : 'A GIFT THEY WILL USE – A smart diary that is used every day, not put away.',
      `MADE TO LAST – ${cover} cover${extrasText ? ` with ${extrasText}` : ''}.`,
      `${f.year ? `READY FOR ${f.year} – ` : 'EVERYDAY PLANNER – '}${f.dated ? 'Dated pages to plan every day of the year.' : 'Plan your days, goals and ideas in one place.'}`,
      `${f.size ? `HANDY ${f.size} SIZE` : 'HANDY SIZE'} – Fits in a bag or on a desk; ${pages} to write freely.`,
      'FOR EVERYONE – Suits men, women, students and professionals.',
    ],
    [ // Short and simple
      personal && 'Your name on the cover – personalise it before you order.',
      `${cover} cover${f.size ? `, ${f.size} size` : ''}.`,
      `${pages[0].toUpperCase()}${pages.slice(1)} for notes and plans.`,
      extrasText && `${extrasText[0].toUpperCase()}${extrasText.slice(1)}.`,
      'Great as a gift for New Year, birthdays and office.',
    ],
  ];
  return sets.map((s) => s.filter(Boolean)).filter((s) => s.length >= 3 && !s.some((b) => PROMO.test(b)));
}

export function descriptionIdeas(l) {
  const f = facts(l);
  const cover = [f.color.toLowerCase(), f.material].filter(Boolean).join(' ') || 'durable';
  const what = `${f.brand ? `${f.brand} ` : ''}${f.year ? `${f.year} ` : ''}${f.size ? `${f.size} ` : ''}diary`;
  const extras = [f.closure && f.closure.toLowerCase(), f.penHolder && 'a pen holder', f.ribbon && 'a ribbon bookmark'].filter(Boolean).join(', ');
  const pages = f.pages ? `${f.pages} ${f.ruling ? f.ruling.toLowerCase() : ''} pages`.replace(/\s+/g, ' ') : 'plenty of pages';
  return [
    `Plan your year with the ${what}. It has a ${cover} cover${extras ? `, ${extras}` : ''} and ${pages} for notes, meetings and daily plans.${f.personal ? ' Add a name or short text for the cover using the Customise option, and it becomes a personal gift.' : ''} A smart choice for office, college and home.`,
    `${f.personal ? 'Looking for a gift with a personal touch? ' : ''}This ${what} comes with a ${cover} cover and ${pages}.${f.personal ? ' Personalise the cover with any name before you order.' : ''} It is a practical gift for New Year, birthdays, Diwali, teachers and corporate events.`,
    `${what[0].toUpperCase()}${what.slice(1)}: ${cover} cover, ${pages}${extras ? `, ${extras}` : ''}.${f.personal ? ' Personalised with the name you choose.' : ''} Made for everyday planning at work and at home.`,
  ].map(tidy).filter((d) => !PROMO.test(d));
}

const SEARCH_POOL = ['notebook', 'planner', 'journal', 'organiser', 'organizer', 'personalized', 'customized', 'name', 'diary',
  'gift', 'men', 'women', 'office', 'corporate', 'new year', 'daily', 'agenda', 'executive', 'leather', 'hardcover', 'ruled',
  'students', 'teachers', 'birthday', 'diwali', 'return gift', 'writing', 'to do list', 'memo', 'notepad'];

export function backendIdeas(l, keywords = []) {
  const titleWords = new Set(String(l?.title || '').toLowerCase().match(/[a-z0-9]+/g) || []);
  const f = facts(l);
  const fresh = (w) => w.split(' ').every((x) => !titleWords.has(x));
  const kw = keywords.map((k) => String(k).toLowerCase().trim()).filter(Boolean);
  const pools = [
    [...kw, ...SEARCH_POOL],
    [...SEARCH_POOL.slice(10), ...kw, ...SEARCH_POOL.slice(0, 10)],
    [f.year && `${f.year} planner`, f.size && `${f.size.toLowerCase()} notebook`, ...SEARCH_POOL.filter((w) => w.length > 5), ...kw],
  ];
  return uniq(pools.map((pool) => {
    let out = '';
    const seen = new Set();
    for (const w of pool.filter(Boolean)) {
      if (!fresh(w) || PROMO.test(w)) continue;
      const parts = w.split(' ');
      if (parts.some((x) => seen.has(x))) continue;
      const next = out ? `${out} ${parts.join(' ')}` : parts.join(' ');
      if (utf8Bytes(next) > 249) break;
      out = next; parts.forEach((x) => seen.add(x));
    }
    return out;
  })).filter((s) => s.length > 20);
}

export function ideasFor(field, listing, keywords) {
  if (field === 'title') return titleIdeas(listing);
  if (field === 'bullets') return bulletIdeas(listing).map((b) => b.join('\n'));
  if (field === 'description') return descriptionIdeas(listing);
  if (field === 'backend_terms') return backendIdeas(listing, keywords);
  return [];
}
