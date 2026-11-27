// Growth > WhatsApp: automatic WhatsApp for every new lead (migration 150).
// A new lead gets the welcome template, replies are answered by the flow (Flow & replies), and anything the bot can't
// handle lands in Inbox for a person. Sections: Inbox, Contacts | Flow & replies, Templates | Results | Setup, Settings.
// Address: #/whatsapp/<section>?c=<chat id>, so phone alerts and lead links open the right chat.
import { lazy, Suspense } from 'react';
import SectionNav from './SectionNav';
import Icon from './icons';
import LoadingSpinner from './LoadingSpinner';
import { navigate, useRoute } from '../utils/route';
import { WorkingBar } from './adsKit';
import { Pill, rpc, useLoad } from './whatsapp/kit';

const Inbox = lazy(() => import('./whatsapp/Inbox'));
const Contacts = lazy(() => import('./whatsapp/Contacts'));
const Flow = lazy(() => import('./whatsapp/Flow'));
const Templates = lazy(() => import('./whatsapp/Templates'));
const Insights = lazy(() => import('./whatsapp/Insights'));
const Setup = lazy(() => import('./whatsapp/Setup'));
const Settings = lazy(() => import('./whatsapp/Settings'));

export default function WhatsApp({ access }) {
  const route = useRoute();
  const manage = !!access?.can_manage;
  const [ov, reload] = useLoad(() => rpc('api_wa_overview'), [], { refreshMs: 30000 });
  const setupDone = ov && ov.setup_ok >= ov.setup_total;
  const groups = [
    { label: 'Chats', items: [
      { id: 'inbox', label: 'Inbox', icon: 'inbox', hint: 'Every chat; take over any time', count: ov?.needs_human || 0 },
      { id: 'contacts', label: 'Contacts', icon: 'leads', hint: 'Opt-ins and opt-outs' }] },
    { label: 'Automation', items: [
      { id: 'flow', label: 'Flow & replies', icon: 'zap', hint: 'What the bot says and when' },
      { id: 'templates', label: 'Templates', icon: 'form', hint: 'Messages Meta approves' }] },
    { label: 'Results', items: [{ id: 'insights', label: 'Insights', icon: 'chart', hint: 'Replies, bookings and cost by source' }] },
    manage && { label: 'Setup', items: [
      { id: 'setup', label: 'Setup', icon: 'checkCircle', hint: ov ? `${ov.setup_ok} of ${ov.setup_total} done` : 'Connect WhatsApp', count: ov && !setupDone ? ov.setup_total - ov.setup_ok : 0 },
      { id: 'settings', label: 'Settings', icon: 'settings', hint: 'Go live, test numbers, timing' }] },
  ].filter(Boolean);
  const ids = groups.flatMap((g) => g.items.map((i) => i.id));
  const fallback = manage && ov && !setupDone && !ov.enabled ? 'setup' : 'inbox';
  const section = ids.includes(route.section) ? route.section : fallback;
  const go = (id) => navigate('whatsapp', id);
  // Phones and tablets: an open chat gets the whole screen (the header and section tabs come back with the back arrow).
  const chatOpen = section === 'inbox' && !!route.params.c;
  const wide = chatOpen ? 'hidden lg:flex' : 'flex';

  const state = !ov ? null : ov.pause_all ? ['Paused', 'red', 'The bot and follow-ups are stopped. You can still reply by hand.']
    : !ov.enabled ? ['Not live', 'gray', 'Only test numbers get messages until you go live in Settings.']
      : ov.test_mode ? ['Test mode', 'orange', 'Live, but only test numbers get messages.'] : ['Live', 'green', 'Every new lead gets a WhatsApp welcome.'];

  return (
    <div className="space-y-4" data-testid="whatsapp">
      <WorkingBar />
      <div className={`glass-card p-4 ${wide} flex-wrap items-center gap-3`}>
        <span className="h-11 w-11 rounded-[13px] inline-flex items-center justify-center text-white shrink-0" style={{ background: 'linear-gradient(160deg, #3BD16F, #1FA855)' }}>
          <Icon name="chat" size={22} />
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-bold text-glass-primary">WhatsApp</h1>
            {state && <Pill tone={state[1]} title={state[2]}>{state[0]}</Pill>}
          </div>
          <div className="text-sm text-glass-secondary truncate">
            {ov?.number?.display_phone ? `${ov.number.verified_name || 'Business number'} · ${ov.number.display_phone}` : 'Automatic welcome and replies for every new lead'}
          </div>
        </div>
        {ov && (
          <div className="grid grid-cols-3 gap-2 w-full sm:w-auto">
            {[['Welcomed today', ov.today?.welcomed], ['Replies today', ov.today?.replies], ['Need a person', ov.needs_human]].map(([l, v], i) => (
              <button key={l} type="button" onClick={() => (i === 2 ? navigate('whatsapp', 'inbox', { f: 'human' }) : go('inbox'))}
                className="glass-stat px-3 py-2 text-left min-w-[92px]">
                <div className="text-[11px] text-glass-secondary truncate">{l}</div>
                <div className="text-lg font-bold" style={{ color: i === 2 && v ? '#B25E00' : undefined }}>{v ?? 0}</div>
              </button>
            ))}
          </div>
        )}
      </div>

      {manage && ov && !setupDone && section !== 'setup' && !chatOpen && (
        <button type="button" onClick={() => go('setup')} className="w-full glass-card p-3 flex items-center gap-3 text-left" style={{ borderLeft: '4px solid #FF9500' }}>
          <Icon name="alert" size={18} /><span className="flex-1 text-sm"><b>Setup: {ov.setup_ok} of {ov.setup_total} steps done.</b> Finish it to start messaging leads.</span>
          <Icon name="chevronRight" size={16} />
        </button>
      )}
      {ov?.queue_dead > 0 && manage && !chatOpen && (
        <div className="glass-card p-3 text-sm flex items-center gap-2" style={{ borderLeft: '4px solid #FF3B30' }}>
          <Icon name="alert" size={16} />{ov.queue_dead} message{ov.queue_dead === 1 ? '' : 's'} could not be sent in the last 7 days. The reason shows in each chat.
        </div>
      )}

      <div className={chatOpen ? 'hidden lg:block' : ''}><SectionNav groups={groups} value={section} onChange={go} /></div>

      <Suspense fallback={<LoadingSpinner />}>
        {section === 'inbox' && <Inbox manage={manage} onChange={reload} />}
        {section === 'contacts' && <Contacts />}
        {section === 'flow' && <Flow manage={manage} />}
        {section === 'templates' && <Templates manage={manage} />}
        {section === 'insights' && <Insights />}
        {section === 'setup' && manage && <Setup onChange={reload} />}
        {section === 'settings' && manage && <Settings isAdmin={!!access?.is_admin} onChange={reload} />}
      </Suspense>
    </div>
  );
}
