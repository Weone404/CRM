// Small helpers shared by the lead window, the Leads list and the Today card.
// Dates are picked and shown in India time (IST, UTC+05:30): every user of this CRM works from India.

const pad = (n) => String(n).padStart(2, '0');
export const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const today = () => ymd(new Date());
export const addDays = (s, n) => { const d = new Date(`${s}T12:00:00`); d.setDate(d.getDate() + n); return ymd(d); };
export const nextMonday = () => { const d = new Date(); const k = (8 - d.getDay()) % 7 || 7; d.setDate(d.getDate() + k); return ymd(d); };

// The moment saved in the database. A day without a time is kept at 9:30 AM so it sorts with that morning.
export const toIso = (date, time) => `${date}T${time || '09:30'}:00+05:30`;

const DAY = new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Asia/Kolkata' });
const TIME = new Intl.DateTimeFormat('en-IN', { hour: 'numeric', minute: '2-digit', hour12: true, timeZone: 'Asia/Kolkata' });
const istYmd = (iso) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date(iso));

export const timeLabel = (hhmm) => {
  if (!hhmm) return '';
  const [h, m] = hhmm.split(':').map(Number);
  return `${((h + 11) % 12) + 1}:${pad(m)} ${h < 12 ? 'AM' : 'PM'}`;
};

// "Today", "Tomorrow", "Fri, 28 Nov" (+ time when there is one)
export function dayWord(date) {
  const t = today();
  if (date === t) return 'Today';
  if (date === addDays(t, 1)) return 'Tomorrow';
  if (date === addDays(t, -1)) return 'Yesterday';
  return DAY.format(new Date(`${date}T12:00:00+05:30`));
}
export const whenPicked = (date, time) => (date ? `${dayWord(date)}${time ? `, ${timeLabel(time)}` : ''}` : '');
export const whenIso = (iso, hasTime = true) => {
  if (!iso) return '';
  const d = istYmd(iso);
  return `${dayWord(d)}${hasTime ? `, ${TIME.format(new Date(iso)).toUpperCase()}` : ''}`;
};
export const isPastIso = (iso) => iso && Date.parse(iso) < Date.now();

// Hot / Warm / Cold, from what the team has already recorded (never a guess about the person).
//   Hot:  a demo is booked or was attended, or Interested with the next call within 3 days
//   Warm: Interested or Callback, or a next call is planned
//   Cold: contacted, but nothing planned (or not reachable)
export function temperature(lead) {
  if (!lead || lead.closed || lead.status === 'closed' || lead.status === 'Not interested') return null;
  if (!lead.first_contacted_at && !lead.demo && !lead.next_followup_at) return null;
  const demo = lead.demo && ['scheduled', 'attended'].includes(lead.demo.status);
  const soon = lead.next_followup_at && Date.parse(lead.next_followup_at) - Date.now() < 3 * 864e5;
  if (demo || (lead.status === 'Interested' && soon)) return 'hot';
  if (['Interested', 'Callback'].includes(lead.status) || lead.next_followup_at) return 'warm';
  return 'cold';
}
export const TEMP = {
  hot: { label: 'Hot', fg: '#C4261D', bg: 'rgba(255,59,48,0.12)', dot: '#FF3B30' },
  warm: { label: 'Warm', fg: '#A35A00', bg: 'rgba(255,149,0,0.14)', dot: '#FF9500' },
  cold: { label: 'Cold', fg: '#0058C2', bg: 'rgba(0,122,255,0.10)', dot: '#5AC8FA' },
};

// DGCA's rule today: CPL training needs Class 12 with Physics and Maths. (A 2025 proposal to relax it for Arts and
// Commerce students has not been notified, so it is not applied here.)
export function cplHint(p) {
  if (!p?.class12) return null;
  const pm = ['pcm', 'pcmb'].includes(p.class12_stream);
  if (p.class12 === 'completed' && pm) return { tone: 'green', text: 'Eligible for CPL: Class 12 with Physics & Maths.' };
  if (p.class12 === 'appearing' && pm) return { tone: 'blue', text: 'Eligible for CPL once Class 12 (Physics & Maths) is passed.' };
  if (p.class12 === 'not_done') return { tone: 'orange', text: 'Class 12 is needed for CPL. Suggest NIOS.' };
  if (p.class12_stream && !pm) return { tone: 'orange', text: 'CPL needs Physics & Maths in Class 12. Suggest NIOS to add them.' };
  return null;
}

export const STREAMS = [['pcm', 'PCM'], ['pcmb', 'PCMB'], ['pcb', 'PCB'], ['commerce', 'Commerce'], ['arts', 'Arts'], ['other', 'Other']];
export const FINANCE = [['loan', 'Loan'], ['emi', 'EMI'], ['scholarship', 'Scholarship']];
export const STUDY = [['appearing', 'Appearing'], ['completed', 'Completed'], ['not_done', 'Not done']];
export const label = (list, v) => (list.find(([k]) => k === v) || [, v])[1];
