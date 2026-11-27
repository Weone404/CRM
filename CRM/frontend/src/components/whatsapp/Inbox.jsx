// WhatsApp > Inbox: every chat, newest first. Laptops: list and chat side by side. Phones: the list, then the chat
// full width with a back arrow. The list refreshes every 8 s and an open chat every 4 s (only while on screen).
// Anyone with access can take over a chat (the bot stops for it), reply, send the brochure or a template, add notes,
// hand it back to the bot or close it.
import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from '../icons';
import { setParams, useRoute, navigate } from '../../utils/route';
import { showToast } from '../../utils/toast';
import { confirmDialog } from '../ui/dialogs';
import {
  admin, ago, BRAND, Btn, clock, day, Empty, ErrorBox, More, phoneOf, Pill, rpc, run, SOURCE, Spinner, STATUS, Ticks, useLoad, useTick,
} from './kit';

const FILTERS = [['all', 'All'], ['human', 'Needs a person'], ['unread', 'Unread'], ['bot', 'With bot'], ['closed', 'Closed']];

export default function Inbox({ manage, onChange }) {
  const route = useRoute();
  const sel = route.params.c || '';
  const filter = route.params.f || 'all';
  const brand = route.params.b || '';
  const [q, setQ] = useState(route.params.q || '');
  const [debounced, setDebounced] = useState(q);
  useEffect(() => { const t = setTimeout(() => setDebounced(q), 300); return () => clearTimeout(t); }, [q]);
  const [list, reloadList, listErr, listLoading] = useLoad(
    () => rpc('api_wa_inbox', { p_filter: filter, p_search: debounced || null, p_brand: brand || null, p_limit: 100 }),
    [filter, debounced, brand], { refreshMs: 8000 });
  useTick();

  const open = (id) => setParams({ c: id });
  const back = () => setParams({ c: undefined });

  return (
    <div className="grid grid-cols-1 lg:grid-cols-[minmax(300px,380px)_minmax(0,1fr)] gap-4 items-start">
      {/* chat list */}
      <section className={`glass-card p-0 overflow-hidden min-w-0 ${sel ? 'hidden lg:block' : ''}`} aria-label="Chats">
        <div className="p-3 space-y-2 border-b" style={{ borderColor: 'var(--hairline)' }}>
          <div className="relative">
            <span className="absolute left-3 top-1/2 -translate-y-1/2 text-glass-secondary"><Icon name="search" size={16} /></span>
            <input className="glass-input w-full pl-9" placeholder="Search name or number" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search chats" />
          </div>
          <div className="flex gap-1.5 overflow-x-auto no-scrollbar -mx-1 px-1 pb-0.5">
            {FILTERS.map(([id, label]) => (
              <button key={id} type="button" onClick={() => setParams({ f: id === 'all' ? undefined : id })}
                className="px-3 py-1.5 rounded-full text-[13px] font-semibold whitespace-nowrap"
                style={filter === id ? { background: '#007AFF', color: '#fff' } : { background: 'rgba(118,118,128,0.12)', color: '#3C3C43' }}>{label}</button>
            ))}
            <select className="glass-input py-1 text-[13px] min-w-[120px]" value={brand} onChange={(e) => setParams({ b: e.target.value || undefined })} aria-label="Brand">
              <option value="">Both brands</option><option value="aviation">We One Aviation</option><option value="charter">Book My Charter</option>
            </select>
          </div>
        </div>
        <ErrorBox error={listErr} onRetry={reloadList} />
        <ul className="max-h-[calc(100dvh-330px)] lg:max-h-[calc(100vh-320px)] min-h-[240px] overflow-y-auto" role="list">
          {!list && listLoading && <li className="p-6 text-center"><Spinner /></li>}
          {list && !list.length && (
            <li><Empty icon="inbox" title={debounced ? 'No chat matches' : 'No chats yet'}>
              {debounced ? 'Try another name or number.' : 'When a new lead gets the welcome message, or someone writes to the number, the chat appears here.'}
            </Empty></li>
          )}
          {(list || []).map((c) => {
            const [label, tone] = STATUS[c.status] || STATUS.bot;
            return (
              <li key={c.id}>
                <button type="button" onClick={() => open(c.id)} aria-current={sel === c.id ? 'true' : undefined}
                  className="w-full text-left px-3 py-3 flex gap-3 items-start transition"
                  style={{ background: sel === c.id ? 'var(--accent-light)' : undefined, borderBottom: '1px solid var(--hairline)' }}>
                  <Avatar name={c.name} brand={c.brand} />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2">
                      <span className={`truncate text-[15px] ${c.unread ? 'font-bold' : 'font-semibold'} text-glass-primary`}>{c.name}</span>
                      <span className="ml-auto text-[11px] text-glass-secondary shrink-0">{ago(c.last_message_at)}</span>
                    </span>
                    <span className="flex items-center gap-1.5 mt-0.5">
                      {c.last_out_status && <Ticks status={c.last_out_status} />}
                      <span className={`truncate text-[13px] ${c.unread ? 'text-glass-primary' : 'text-glass-secondary'}`}>{c.last_preview || '—'}</span>
                      {c.unread > 0 && <span className="ml-auto shrink-0 min-w-[20px] h-5 px-1.5 rounded-full text-[11px] font-bold text-white inline-flex items-center justify-center" style={{ background: '#1FA855' }}>{c.unread}</span>}
                    </span>
                    <span className="flex flex-wrap gap-1 mt-1">
                      {c.status !== 'bot' && <Pill tone={tone}>{label}</Pill>}
                      {c.opted_out && <Pill tone="red">Opted out</Pill>}
                      {c.not_on_whatsapp && <Pill tone="red">Not on WhatsApp</Pill>}
                      <Pill>{SOURCE[c.source] || c.source || 'Lead'}</Pill>
                      {c.brand === 'charter' && <Pill tone="purple">Charter</Pill>}
                    </span>
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      </section>

      {/* open chat */}
      <section className={`min-w-0 ${sel ? '' : 'hidden lg:block'}`} aria-label="Chat">
        {sel ? <Thread key={sel} id={sel} manage={manage} onBack={back} onChange={() => { reloadList(); onChange?.(); }} />
          : <div className="glass-card"><Empty icon="chat" title="Pick a chat">Tap any chat on the left to read it and reply.</Empty></div>}
      </section>
    </div>
  );
}

function Avatar({ name, brand }) {
  const ch = String(name || '?').trim().charAt(0).toUpperCase() || '?';
  return (
    <span className="h-10 w-10 rounded-full inline-flex items-center justify-center text-white font-bold shrink-0"
      style={{ background: brand === 'charter' ? 'linear-gradient(160deg,#B67CF0,#8E3BB8)' : 'linear-gradient(160deg,#3BD16F,#1FA855)' }}>{ch}</span>
  );
}

function Thread({ id, manage, onBack, onChange }) {
  const [t, reload, err] = useLoad(() => rpc('api_wa_thread', { p_conv: id }), [id], { refreshMs: 4000 });
  const scroller = useRef(null);
  const lastId = useRef(0);
  useTick();
  useEffect(() => { rpc('api_wa_read', { p_conv: id }).then(() => onChange?.(), () => {}); }, [id]);   // eslint-disable-line react-hooks/exhaustive-deps
  const msgs = t?.messages || [];
  useEffect(() => {                                   // keep the newest message in view
    const last = msgs[msgs.length - 1]?.id || 0;
    if (last !== lastId.current && scroller.current) { scroller.current.scrollTop = scroller.current.scrollHeight; lastId.current = last; }
  }, [msgs]);
  if (err && !t) return <div className="glass-card p-4"><ErrorBox error={err} onRetry={reload} /></div>;
  if (!t) return <div className="glass-card p-8 text-center"><Spinner /></div>;
  const v = t.conversation, c = t.contact, lead = t.lead;
  const name = c.name || c.profile_name || phoneOf(c);
  const [label, tone] = STATUS[v.status] || STATUS.bot;
  const setStatus = (s) => run(rpc('api_wa_set_status', { p_conv: id, p_status: s }),
    s === 'human' ? 'You have this chat. The bot is paused for it.' : s === 'bot' ? 'Handed back to the bot' : 'Chat closed').then(() => { reload(); onChange?.(); });

  return (
    <div className="glass-card p-0 overflow-hidden flex flex-col min-w-0">
      {/* header */}
      <div className="flex items-center gap-2 px-3 py-2.5 border-b" style={{ borderColor: 'var(--hairline)' }}>
        <button type="button" onClick={onBack} className="lg:hidden h-9 w-9 rounded-full inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(118,118,128,0.12)' }} aria-label="Back to chats">
          <Icon name="chevronLeft" size={18} />
        </button>
        <Avatar name={name} brand={v.brand} />
        <div className="min-w-0 flex-1">
          <div className="font-semibold text-glass-primary truncate">{name}</div>
          <div className="text-xs text-glass-secondary truncate">{phoneOf(c)} · {BRAND[v.brand]}{v.assigned_name ? ` · ${v.assigned_name}` : ''}</div>
        </div>
        <Pill tone={tone}>{label}</Pill>
        {c.phone10 && <a href={`tel:${c.phone10}`} className="h-9 w-9 rounded-full inline-flex items-center justify-center shrink-0" style={{ background: 'rgba(52,199,89,0.14)', color: '#1E8E3E' }} aria-label="Call"><Icon name="phone" size={17} /></a>}
      </div>

      {/* what the bot knows + actions */}
      <div className="px-3 py-2 flex flex-wrap gap-2 items-center border-b" style={{ borderColor: 'var(--hairline)' }}>
        {v.status === 'bot' && <Btn onClick={() => setStatus('human')} tone="#FF9500">Take over</Btn>}
        {v.status === 'human' && <Btn onClick={() => setStatus('bot')} ghost>Hand back to bot</Btn>}
        {v.status !== 'closed' ? <Btn onClick={async () => { if (await confirmDialog('Close this chat?', { message: 'It moves to Closed. If they write again it opens by itself.' })) await setStatus('closed'); }} ghost>Close</Btn>
          : <Btn onClick={() => setStatus('bot')} ghost>Reopen</Btn>}
        {lead?.kind === 'lead' && <Btn ghost onClick={() => navigate('leads', '', { lead: lead.id })}><Icon name="leads" size={15} />Open lead</Btn>}
        <span className="ml-auto text-xs text-glass-secondary">{v.window_open ? <WindowTimer ends={v.window_ends_at} /> : 'Over 24 h since they wrote: templates only'}</span>
      </div>
      {(c.opted_out || c.not_on_whatsapp) && (
        <div className="px-3 py-2 text-sm" style={{ background: 'rgba(255,59,48,0.08)', color: '#C4291F' }}>
          {c.opted_out ? 'They asked not to get messages. The bot will not write to them.' : 'This number could not get WhatsApp messages. Call them instead.'}
        </div>
      )}

      {/* messages */}
      <div ref={scroller} className="flex-1 overflow-y-auto px-3 py-3 space-y-1.5 h-[calc(100dvh-330px)] lg:h-[calc(100vh-420px)] min-h-[260px]"
        style={{ background: 'rgba(118,118,128,0.05)' }} aria-live="polite">
        {!msgs.length && <Empty icon="chat" title="No messages yet">{(t.queue || []).length ? 'A message is waiting to be sent.' : 'Nothing has been sent to this person yet.'}</Empty>}
        {msgs.map((m, i) => (
          <div key={m.id}>
            {(i === 0 || day(m.created_at) !== day(msgs[i - 1].created_at)) && (
              <div className="text-center my-2"><span className="text-[11px] px-2 py-0.5 rounded-full text-glass-secondary" style={{ background: 'rgba(255,255,255,0.8)' }}>{day(m.created_at)}</span></div>
            )}
            <Bubble m={m} />
          </div>
        ))}
        {(t.queue || []).filter((x) => x.state !== 'done').slice(0, 3).map((x) => (
          <div key={x.id} className="text-center text-[11px] text-glass-secondary">
            {x.state === 'dead' ? <span style={{ color: '#C4291F' }}>Not sent: {x.last_error}</span> : `Waiting to send (${x.kind})${x.last_error ? `: ${x.last_error}` : ''}`}
          </div>
        ))}
      </div>

      <Composer t={t} id={id} reload={reload} onChange={onChange} />

      <div className="p-3 space-y-2 border-t" style={{ borderColor: 'var(--hairline)' }}>
        <More title="Lead and what the bot learned">
          <div className="grid sm:grid-cols-2 gap-x-4 gap-y-1 text-sm">
            {lead ? <>
              <Info k="Lead" v={lead.name} /><Info k="Course" v={lead.course} /><Info k="Status" v={lead.status} />
              <Info k="Came from" v={SOURCE[v.source] || lead.source || v.source} /><Info k="Assigned" v={lead.assigned} />
              <Info k="Enquired" v={lead.created_at && new Date(lead.created_at).toLocaleString('en-IN')} />
            </> : <div className="text-glass-secondary">Not linked to a lead.</div>}
            <Info k="Step" v={v.current_step} />
            {Object.entries(v.answers || {}).map(([k, val]) => <Info key={k} k={k[0].toUpperCase() + k.slice(1)} v={val} />)}
            <Info k="Opt-in" v={c.opt_in_source ? `${SOURCE[c.opt_in_source] || c.opt_in_source}` : 'Not recorded'} />
          </div>
        </More>
        <Notes t={t} id={id} reload={reload} />
        <More title="Bot activity">
          <ul className="text-xs text-glass-secondary space-y-1">
            {(t.events || []).map((e, i) => <li key={i}><b className="text-glass-primary">{e.kind.replace(/_/g, ' ')}</b> · {ago(e.created_at)}{e.detail?.reason ? ` · ${e.detail.reason}` : ''}</li>)}
            {!(t.events || []).length && <li>Nothing yet.</li>}
          </ul>
        </More>
      </div>
    </div>
  );
}

const Info = ({ k, v }) => (v ? <div className="flex gap-2 min-w-0"><span className="text-glass-secondary shrink-0">{k}</span><span className="truncate text-glass-primary">{String(v)}</span></div> : null);

function WindowTimer({ ends }) {
  const ms = new Date(ends).getTime() - Date.now();
  if (ms <= 0) return 'Templates only';
  const h = Math.floor(ms / 3600000), m = Math.floor((ms % 3600000) / 60000);
  return <span title="WhatsApp lets you type freely for 24 hours after their last message">Free text for {h ? `${h}h ` : ''}{m}m</span>;
}

function Bubble({ m }) {
  const out = m.direction === 'out';
  const who = out ? (m.sent_by === 'bot' ? 'Bot' : m.sent_by === 'system' ? 'Auto' : m.sent_by || 'Staff') : null;
  return (
    <div className={`flex ${out ? 'justify-end' : 'justify-start'}`}>
      <div className="max-w-[85%] sm:max-w-[70%] min-w-0 rounded-2xl px-3 py-2 text-[14px] leading-snug shadow-sm break-words"
        style={{ background: out ? (m.status === 'failed' ? 'rgba(255,59,48,0.10)' : '#DCF8C6') : '#fff', borderTopRightRadius: out ? 6 : undefined, borderTopLeftRadius: out ? undefined : 6 }}>
        {m.template_name && <div className="text-[11px] font-semibold mb-0.5" style={{ color: '#1E8E3E' }}>Template · {m.template_name}</div>}
        {m.kind === 'document' && <div className="flex items-center gap-1.5 text-[13px] font-semibold mb-0.5"><Icon name="policy" size={14} />{m.filename || 'Document'}</div>}
        {['image', 'audio', 'video', 'sticker', 'voice'].includes(m.kind) && <div className="text-[13px] font-semibold mb-0.5">{({ image: '📷 Photo', audio: '🎤 Voice note', voice: '🎤 Voice note', video: '🎬 Video', sticker: 'Sticker' })[m.kind]}{m.media_path ? ' (saved)' : ''}</div>}
        {m.body && <div className="whitespace-pre-wrap break-words">{m.body}</div>}
        {Array.isArray(m.buttons) && m.buttons.length > 0 && (
          <div className="flex flex-wrap gap-1 mt-1.5">{m.buttons.map((b) => <span key={b} className="text-[12px] px-2 py-0.5 rounded-full" style={{ background: 'rgba(0,122,255,0.1)', color: '#0A63CE' }}>{b}</span>)}</div>
        )}
        {m.status === 'failed' && <div className="text-[12px] mt-1" style={{ color: '#C4291F' }}>Not delivered{m.error_text ? `: ${m.error_text}` : ''}</div>}
        <div className="flex items-center justify-end gap-1 mt-0.5 text-[10.5px] text-glass-secondary">
          {who && <span>{who} ·</span>}{clock(m.created_at)}{out && <Ticks status={m.status} />}
        </div>
      </div>
    </div>
  );
}

function Composer({ t, id, reload, onChange }) {
  const v = t.conversation;
  const [text, setText] = useState('');
  const [tpl, setTpl] = useState('');
  const [templates] = useLoad(() => rpc('api_wa_templates'), []);
  const [settings] = useLoad(() => rpc('api_wa_settings').catch(() => null), []);
  const approved = useMemo(() => ((templates?.templates) || []).filter((x) => x.meta_status === 'approved'), [templates]);
  const send = async (item, okMsg) => {
    await admin('send', { conversation: id, item });
    showToast(okMsg, 'success');
    reload(); onChange?.();
  };
  if (t.contact.opted_out && !v.window_open) return null;
  if (!v.window_open) {
    return (
      <div className="p-3 border-t flex flex-col sm:flex-row gap-2" style={{ borderColor: 'var(--hairline)' }}>
        <select className="glass-input flex-1 min-w-0" value={tpl} onChange={(e) => setTpl(e.target.value)} aria-label="Template">
          <option value="">{approved.length ? 'Pick an approved template…' : 'No approved templates yet'}</option>
          {approved.map((x) => <option key={x.id} value={x.name}>{x.name} ({x.category.toLowerCase()})</option>)}
        </select>
        <Btn disabled={!tpl} onClick={() => send({ type: 'template', name: tpl }, 'Template sent').then(() => setTpl(''))} busyText="Sending">Send template</Btn>
      </div>
    );
  }
  const brochure = settings?.brochure_url;
  return (
    <form className="p-3 border-t flex items-end gap-2" style={{ borderColor: 'var(--hairline)' }}
      onSubmit={(e) => { e.preventDefault(); }}>
      {brochure && (
        <Btn ghost title="Send the brochure PDF" onClick={() => send({ type: 'document', link: brochure, filename: settings.brochure_name || 'brochure.pdf' }, 'Brochure sent')}>
          <Icon name="policy" size={16} /><span className="hidden sm:inline">Brochure</span>
        </Btn>
      )}
      <textarea className="glass-input flex-1 min-w-0 resize-none min-h-[42px] max-h-40" rows={1} placeholder="Type a message" value={text} maxLength={4096}
        onChange={(e) => setText(e.target.value)} aria-label="Message"
        onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey && text.trim()) { e.preventDefault(); const b = text; setText(''); send({ type: 'text', body: b }, 'Sent').catch((x) => { setText(b); showToast(x.message, 'error'); }); } }} />
      <Btn disabled={!text.trim()} onClick={() => { const b = text; setText(''); return send({ type: 'text', body: b }, 'Sent').catch((x) => { setText(b); throw x; }); }} busyText="Sending" aria-label="Send">
        <Icon name="send" size={16} />
      </Btn>
    </form>
  );
}

function Notes({ t, id, reload }) {
  const [body, setBody] = useState('');
  const notes = t.notes || [];
  return (
    <More title={`Team notes${notes.length ? ` (${notes.length})` : ''}`}>
      <div className="flex gap-2 mb-2">
        <input className="glass-input flex-1" placeholder="Only your team sees this" value={body} onChange={(e) => setBody(e.target.value)} maxLength={2000} />
        <Btn disabled={!body.trim()} onClick={() => rpc('api_wa_note_add', { p_conv: id, p_body: body }).then(() => { setBody(''); reload(); })}>Add</Btn>
      </div>
      <ul className="space-y-1.5">
        {notes.map((n) => <li key={n.id} className="text-sm"><span className="text-glass-primary">{n.body}</span> <span className="text-xs text-glass-secondary">· {n.by || 'Staff'} · {ago(n.created_at)}</span></li>)}
      </ul>
    </More>
  );
}
