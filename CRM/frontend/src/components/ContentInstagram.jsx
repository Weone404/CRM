import { useEffect, useState } from 'react';
import { rpc, run, useLoad, Btn } from './adsKit';
import { Switch } from './ui/AppleControls';

// Content > Instagram > Comment-to-DM (migrations 135-137). The ig-dm run (every 2 minutes) reads these settings;
// the token lives in Connections & keys > Meta and is never shown here.

const C = { green: '#1E7B34', amber: '#8A5300', red: '#A42219', muted: 'rgba(0,0,0,0.6)' };
const STATE = {
  ready: ['Connected', C.green], not_connected: ['Not connected', C.amber], needs_permission: ['Needs a permission', C.red],
  error: ['Problem', C.red], check: ['Checking', C.amber],
};
const LOG = { sent: ['DM sent', C.green], public: ['Already messaged: reply only', C.muted], skipped: ['Skipped', C.muted],
  failed: ['Failed', C.red], imported: ['Answered before', C.muted], sending: ['Sending', C.amber] };
const DEFAULT_INVITE = "📄 Reply to this message and we'll send you our {brochure} (PDF) right here.";
const DEFAULT_INTRO = "Here's our {brochure} ✈️";
const ago = (t) => { if (!t) return 'never'; const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 2 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`; };
const inp = 'glass-input w-full px-3 py-2 text-sm';
const preview = (t, name = 'riya_sharma') => String(t || '').replace(/\{name\}/g, `@${name}`);

function Field({ label, hint, children }) {
  return (
    <label className="block">
      <span className="block text-[13px] font-medium text-glass-primary">{label}</span>
      {hint && <span className="block text-[12px] text-glass-secondary mb-1">{hint}</span>}
      {children}
    </label>);
}
function Row({ label, hint, on, onChange, disabled }) {
  return (
    <div className="flex items-center gap-3 py-2 border-t border-[var(--hairline)] first:border-t-0">
      <div className="flex-1"><div className="text-sm">{label}</div>{hint && <div className="text-[12px] text-glass-secondary">{hint}</div>}</div>
      <Switch size="sm" label={label} on={!!on} disabled={disabled} onChange={onChange} />
    </div>);
}

function CommentToDM() {
  const [d, reload] = useLoad(() => rpc('api_ig_dm_status'), [], { refreshMs: 60000 });
  const s = d?.settings || {};
  const [f, setF] = useState(null);
  const from = (x) => ({
    message: x.message || '', welcome: x.welcome || '', thanks: x.thanks || '',
    pdf_url: x.pdf_url || '', pdf_name: x.pdf_name || '', pdf_invite: x.pdf_invite || DEFAULT_INVITE, pdf_intro: x.pdf_intro || DEFAULT_INTRO,
    public_replies: (x.public_replies || []).join('\n'), cap: x.cap ?? 60,
  });
  useEffect(() => { if (d && !f) setF(from(s)); }, [d]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!d || !f) return <div className="glass-card p-5 text-sm text-glass-secondary">Loading…</div>;

  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const flip = (k) => (v) => run(rpc('api_ig_dm_settings_save', { p: { [k]: v } }), v ? 'Turned on' : 'Turned off').then(reload);
  const dirty = JSON.stringify(f) !== JSON.stringify(from(s));
  const save = () => run(rpc('api_ig_dm_settings_save', { p: {
    message: f.message, welcome: f.welcome, thanks: f.thanks, pdf_url: f.pdf_url, pdf_name: f.pdf_name,
    pdf_invite: f.pdf_invite === DEFAULT_INVITE ? '' : f.pdf_invite, pdf_intro: f.pdf_intro === DEFAULT_INTRO ? '' : f.pdf_intro,
    public_replies: f.public_replies.split('\n').map((x) => x.trim()).filter(Boolean), cap: Number(f.cap) || 60,
  } }), 'Saved: the next run (within 2 minutes) uses it').then((r) => { if (r) { setF(null); reload(); } });
  const [stLabel, stColor] = STATE[s.state] || ['Not connected', C.amber];
  const day = d.last_24h || {};
  const brochure = f.pdf_url ? (f.pdf_name || 'brochure') : '';
  const fill = (t) => String(t || '').replaceAll('{brochure}', brochure || 'brochure');

  return (
    <div className="space-y-3" data-testid="ig-dm">
      <section className="glass-card p-5">
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex-1 min-w-[220px]">
            <h3 className="m-0 text-base font-semibold">Comment-to-DM</h3>
            <p className="m-0 text-[13px] text-glass-secondary">Someone comments on a post: they get your message in their DM and a short reply under the comment. Checked every 2 minutes.</p>
          </div>
          <span className="px-2.5 py-1 rounded-full text-[12px] font-semibold" style={{ color: stColor, background: 'rgba(118,118,128,0.12)' }}>
            {stLabel}{s.username ? ` · @${s.username}` : ''}</span>
          <Switch label="Comment-to-DM on" on={!!s.on} onChange={flip('on')} />
        </div>
        {s.note && <div className="mt-2 text-[13px]" style={{ color: C.amber }}>{s.note}</div>}
        {!d.token_saved && <div className="mt-2 text-[13px]" style={{ color: C.amber }}>Save the Instagram token in Connections &amp; keys &gt; Meta to start.</div>}
        <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-[13px] text-glass-secondary">
          <span>Last 24 h: <b className="text-glass-primary">{day.sent ?? 0}</b> DMs</span>
          <span><b className="text-glass-primary">{d.brochures ?? 0}</b> brochures</span>
          <span><b className="text-glass-primary">{d.phones ?? 0}</b> numbers received</span>
          <span><b className="text-glass-primary">{day.skipped ?? 0}</b> skipped (spam / angry)</span>
          {(day.failed ?? 0) > 0 && <span style={{ color: C.red }}>{day.failed} failed</span>}
          <span>Checked {ago(s.checked_at)}</span>
        </div>
      </section>

      <section className="glass-card p-5 space-y-4">
        <h3 className="m-0 text-base font-semibold">Messages</h3>
        <Field label="DM to people who comment" hint="{name} becomes their Instagram username. Instagram allows one message until they reply, so keep the key details here.">
          <textarea rows={6} maxLength={900} className={inp} value={f.message} onChange={set('message')} aria-label="DM to people who comment" />
        </Field>
        <Field label="Welcome for people who message you first" hint="Leave empty to send the same DM as above.">
          <textarea rows={3} maxLength={900} className={inp} value={f.welcome} onChange={set('welcome')} placeholder="Same as the comment DM" aria-label="Welcome for people who message first" />
        </Field>
        <Field label="Reply when they send their mobile number" hint="The number also becomes a lead in the CRM.">
          <input maxLength={500} className={inp} value={f.thanks} onChange={set('thanks')} aria-label="Reply when they send their number" />
        </Field>
        <Field label="Replies under the comment" hint="One per line; they are used in turn so the replies don't all look the same.">
          <textarea rows={3} className={inp} value={f.public_replies} onChange={set('public_replies')} aria-label="Replies under the comment" />
        </Field>
      </section>

      <section className="glass-card p-5 space-y-4">
        <h3 className="m-0 text-base font-semibold">Brochure (PDF)</h3>
        <div className="grid sm:grid-cols-[1fr_200px] gap-3">
          <Field label="PDF link" hint="A public https link to a PDF up to 25 MB. Empty = no brochure.">
            <input className={inp} value={f.pdf_url} onChange={set('pdf_url')} placeholder="https://…/brochure.pdf" aria-label="Brochure PDF link" />
          </Field>
          <Field label="Called" hint="Shown as {brochure}">
            <input maxLength={40} className={inp} value={f.pdf_name} onChange={set('pdf_name')} placeholder="brochure" aria-label="Brochure name" />
          </Field>
        </div>
        {f.pdf_url && <a className="text-[13px]" href={f.pdf_url} target="_blank" rel="noreferrer">Open the PDF</a>}
        <Field label="Line added to the comment DM" hint="Asks them to reply, because the PDF can only go once they answer.">
          <input maxLength={300} className={inp} value={f.pdf_invite} onChange={set('pdf_invite')} disabled={!f.pdf_url} aria-label="Brochure invite line" />
        </Field>
        <Field label="Message sent with the PDF">
          <input maxLength={300} className={inp} value={f.pdf_intro} onChange={set('pdf_intro')} disabled={!f.pdf_url} aria-label="Message sent with the PDF" />
        </Field>
      </section>

      <section className="glass-card p-5">
        <h3 className="m-0 mb-1 text-base font-semibold">Preview</h3>
        <p className="m-0 mb-2 text-[12px] text-glass-secondary">What @riya_sharma gets after commenting.</p>
        <div className="rounded-2xl px-4 py-3 text-sm whitespace-pre-wrap" style={{ background: 'rgba(118,118,128,0.10)' }}>
          {preview(f.message)}{brochure ? `\n\n${fill(f.pdf_invite)}` : ''}</div>
        {brochure && <div className="mt-2 text-[12px] text-glass-secondary">When she replies: “{fill(f.pdf_intro)}” and the PDF.</div>}
      </section>

      <section className="glass-card p-5">
        <h3 className="m-0 mb-1 text-base font-semibold">Options</h3>
        <Row label="Reply under the comment" hint="“Check your inbox” style reply, so others see you answer." on={s.public_reply !== false} onChange={flip('public_reply')} />
        <Row label="Answer people who message first" hint="Welcome message, and the brochure if one is set." on={s.inbox !== false} onChange={flip('inbox')} />
        <Row label="Mobile numbers become CRM leads" on={s.crm !== false} onChange={flip('crm')} />
        <div className="flex items-center gap-3 py-2 border-t border-[var(--hairline)]">
          <div className="flex-1"><div className="text-sm">Most messages per hour</div><div className="text-[12px] text-glass-secondary">A safety limit (1 to 200).</div></div>
          <input type="number" min={1} max={200} className="glass-input w-24 px-3 py-2 text-sm text-right" value={f.cap} onChange={set('cap')} aria-label="Most messages per hour" />
        </div>
      </section>

      <div className={`flex flex-wrap items-center gap-2 ${dirty ? 'sticky bottom-3 z-10 glass-card px-4 py-3' : ''}`}>
        <Btn disabled={!dirty || f.message.trim().length < 10} onClick={save} data-testid="ig-dm-save">Save changes</Btn>
        {dirty && <Btn ghost onClick={() => setF(from(s))}>Undo</Btn>}
        {f.message.trim().length < 10 && <span className="text-[12px]" style={{ color: C.red }}>The DM needs at least 10 characters.</span>}
      </div>

      <section className="glass-card p-5">
        <h3 className="m-0 mb-2 text-base font-semibold">Latest comments</h3>
        {!(d.recent || []).length ? <div className="text-sm text-glass-secondary">No comments handled yet.</div> : (
          <div className="divide-y divide-[var(--hairline)]">{d.recent.map((r, i) => {
            const [l, c] = LOG[r.state] || [r.state, C.muted];
            return (
              <div key={i} className="py-2 flex flex-wrap items-center gap-2 text-[13px]">
                <b>@{r.username}</b><span style={{ color: c }}>{l}{r.reason ? ` (${r.reason})` : ''}</span>
                {r.error && <span style={{ color: C.red }}>{r.error}</span>}
                <span className="flex-1" /><span className="text-glass-secondary">{ago(r.at)}</span>
              </div>);
          })}</div>)}
      </section>
    </div>);
}

export default function ContentInstagram() {
  return (
    <div className="space-y-3">
      <div role="tablist" aria-label="Instagram" className="flex gap-1">
        <span role="tab" aria-selected="true" className="px-3 py-1.5 rounded-full text-[13px] font-semibold" style={{ background: 'rgba(10,99,206,0.10)', color: '#0A63CE' }}>Comment-to-DM</span>
      </div>
      <CommentToDM />
    </div>);
}
