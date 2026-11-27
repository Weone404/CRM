// WhatsApp > Setup: connect the new business number to the CRM, one step at a time. Each step says exactly what to do
// in Meta (or Cloudflare), has the values to copy, and a "Check now" that asks Meta and shows ✓ or the exact fix.
// Secrets are saved straight into Supabase Vault and never shown again (only the last 4 characters).
import { useState } from 'react';
import Icon from '../icons';
import { navigate } from '../../utils/route';
import { promptDialog } from '../ui/dialogs';
import { showToast } from '../../utils/toast';
import { admin, ago, Btn, CopyRow, ErrorBox, Field, More, Pill, rpc, run, Spinner, useLoad } from './kit';

const L = (href, text) => <a href={href} target="_blank" rel="noreferrer noopener" className="font-semibold underline" style={{ color: '#007AFF' }}>{text}</a>;

export default function Setup({ onChange }) {
  const [d, reload, err] = useLoad(() => rpc('api_wa_setup'), [], { refreshMs: 20000 });
  const [settings, reloadSettings] = useLoad(() => rpc('api_wa_settings'), []);
  const refresh = () => { reload(); reloadSettings(); onChange?.(); };
  if (err && !d) return <ErrorBox error={err} onRetry={reload} />;
  if (!d) return <div className="glass-card p-8 text-center"><Spinner /></div>;
  const ck = d.checks || {};
  const done = ['business', 'app', 'number', 'payment', 'token', 'ids', 'webhook', 'subscribed', 'registered', 'templates', 'test'].filter((k) => ck[k]?.ok).length;
  const check = async (steps) => {
    const r = await admin('checks', steps ? { steps } : {});
    const bad = Object.entries(r.results).filter(([, v]) => !v.ok);
    showToast(bad.length ? `${bad.length} step${bad.length > 1 ? 's' : ''} still to do` : 'All checked steps are done', bad.length ? 'info' : 'success');
    refresh();
  };
  const callback = d.gateway_url || d.webhook_url;

  return (
    <div className="space-y-3">
      <div className="glass-card p-4 flex flex-col sm:flex-row sm:items-center gap-3">
        <div className="flex-1">
          <div className="text-lg font-bold text-glass-primary">{done} of 11 done</div>
          <div className="h-2 rounded-full mt-2 overflow-hidden" style={{ background: 'rgba(118,118,128,0.16)' }}>
            <div className="h-full rounded-full" style={{ width: `${(done / 11) * 100}%`, background: '#1FA855', transition: 'width .4s' }} />
          </div>
          <div className="text-xs text-glass-secondary mt-1.5">Use a new number that is not on the WhatsApp app. Meta API version: {d.api_version}.</div>
        </div>
        <Btn onClick={() => check()} busyText="Checking with Meta"><Icon name="refresh" size={15} />Check all</Btn>
      </div>

      <Step k="a" title="Verify your business with Meta" c={ck.business} manual onMark={(ok) => mark('business', ok, refresh)}>
        <p>In {L('https://business.facebook.com/settings/security', 'Meta Business Settings > Security Centre')}, start <b>Business verification</b> for We One Aviation (company documents, website and phone). It lifts the limit from 250 to 2,000+ new people a day.</p>
      </Step>

      <Step k="b" title="Create the Meta app and add WhatsApp" c={ck.app} onCheck={() => check(['app'])}>
        <p>Open {L('https://developers.facebook.com/apps', 'developers.facebook.com/apps')} &gt; <b>Create app</b> &gt; type <b>Business</b> &gt; pick the We One Aviation business portfolio. In the app, <b>Add product &gt; WhatsApp &gt; Set up</b>.</p>
        <p>Then <b>App settings &gt; Basic</b>: copy the <b>App ID</b> and press <b>Show</b> next to App Secret.</p>
        <IdForm label="App ID" field="app_id" value={d.number?.app_id} onSaved={refresh} />
        <SecretForm name="app_secret" label="App Secret" saved={d.secrets?.app_secret} onSaved={refresh} />
      </Step>

      <Step k="c" title="Add the new phone number" c={ck.number} onCheck={() => check(['number'])} extra={d.number?.display_phone && <Pill tone="blue">{d.number.display_phone}</Pill>}>
        <p>In the app: <b>WhatsApp &gt; API Setup &gt; Add phone number</b>. Enter the display name (for example <i>We One Aviation</i>), category <i>Education</i>, then the new number and the OTP Meta sends to it. Meta reviews the display name (usually within a day).</p>
        <p>From the same page copy the <b>Phone number ID</b> and the <b>WhatsApp Business Account ID</b>.</p>
        <div className="grid sm:grid-cols-2 gap-2">
          <IdForm label="Phone number ID" field="phone_number_id" value={d.number?.phone_number_id} onSaved={refresh} />
          <IdForm label="WhatsApp Business Account ID" field="waba_id" value={d.number?.waba_id} onSaved={refresh} />
        </div>
        {d.number?.quality_rating && <div className="text-xs text-glass-secondary">Quality: {d.number.quality_rating} · Limit: {d.number.messaging_limit || 'not shown'} · Name: {d.number.name_status}</div>}
      </Step>

      <Step k="d" title="Add a payment method" c={ck.payment} manual onMark={(ok) => mark('payment', ok, refresh)}>
        <p>Since 1 Oct 2026 Meta needs a payment method on the WhatsApp account for every paid message, replies included. In {L('https://business.facebook.com/wa/manage/home/', 'WhatsApp Manager')} open <b>Settings &gt; Payment methods</b> and add a card. Meta bills you directly; the CRM adds no charges.</p>
      </Step>

      <Step k="e" title="Create a permanent access token" c={ck.token} onCheck={() => check(['token'])}>
        <ol className="list-decimal pl-5 space-y-1">
          <li>{L('https://business.facebook.com/settings/system-users', 'Business Settings > Users > System users')} &gt; <b>Add</b>: name <i>CRM WhatsApp</i>, role <b>Admin</b>.</li>
          <li><b>Assign assets</b>: the app (Full control) and the WhatsApp account (Full control).</li>
          <li><b>Generate new token</b> &gt; pick the app &gt; expiry <b>Never</b> &gt; tick <code>whatsapp_business_messaging</code> and <code>whatsapp_business_management</code>.</li>
          <li>Paste it below. It is stored in the Vault and never shown again.</li>
        </ol>
        <SecretForm name="access_token" label="Access token" saved={d.secrets?.access_token} onSaved={refresh} />
      </Step>

      <Step k="f" title="Confirm the number and account match" c={ck.ids} onCheck={() => check(['ids'])}>
        <p>Checks that the Phone number ID belongs to the WhatsApp Business Account you saved.</p>
      </Step>

      <Step k="g" title="Connect Meta's messages to the CRM (Cloudflare gateway)" c={ck.webhook} onCheck={() => check(['webhook'])}>
        <More title="1. Deploy the free Cloudflare gateway (once, on your Mac)" defaultOpen={!d.gateway_url}>
          <p className="mb-2">It keeps a copy of every WhatsApp message and re-sends it if the CRM is ever down, so nothing is lost. In Terminal, in the CRM folder:</p>
          <pre className="text-xs rounded-xl p-3 overflow-x-auto" style={{ background: '#1C1C1E', color: '#E5E5EA' }}>{`cd CRM/tools/wa-gateway
npx wrangler login
npx wrangler d1 create weone-wa-gateway      # copy the database_id into wrangler.toml
npx wrangler d1 execute weone-wa-gateway --remote --file=schema.sql
npx wrangler secret put APP_SECRET           # paste the Meta App Secret
npx wrangler deploy                          # prints https://weone-wa-gateway.<you>.workers.dev`}</pre>
          <GatewayForm value={d.gateway_url} onSaved={refresh} />
          {d.gateway_url && <div className="text-xs text-glass-secondary mt-1">{d.gateway_seen_at ? `Gateway delivered a message ${ago(d.gateway_seen_at)} ago.` : 'No message through the gateway yet.'} {L(`${d.gateway_url}/health`, 'Gateway health')}</div>}
        </More>
        <p className="mt-2"><b>2.</b> In the Meta app: <b>WhatsApp &gt; Configuration &gt; Webhook &gt; Edit</b>. Paste these two, press <b>Verify and save</b>:</p>
        <div className="grid gap-2">
          <CopyRow label={d.gateway_url ? 'Callback URL (Cloudflare gateway)' : 'Callback URL (direct; add the gateway above for safety)'} value={callback} />
          <div className="flex gap-2 items-stretch">
            <div className="flex-1"><CopyRow label="Verify token" value={d.verify_token} /></div>
            <Btn ghost onClick={() => run(rpc('api_wa_verify_token_new'), 'New verify token made').then(refresh)}>{d.verify_token ? 'New' : 'Make one'}</Btn>
          </div>
        </div>
        <p className="mt-2"><b>3.</b> Under <b>Webhook fields</b>, press <b>Subscribe</b> next to <code>messages</code>.</p>
        <p><b>4.</b> From your own phone, send any WhatsApp message to the new business number, then Check now.</p>
        <div className="text-xs text-glass-secondary">{d.webhook_seen_at ? `Meta reached the CRM ${ago(d.webhook_seen_at)} ago.` : 'Meta has not reached the CRM yet.'} {d.last_inbound_at ? `Last message received ${ago(d.last_inbound_at)} ago.` : ''}</div>
      </Step>

      <Step k="h" title="Subscribe the app to the number's messages" c={ck.subscribed} onCheck={() => check(['subscribed'])}>
        <p>One click: tells Meta to send this WhatsApp account's messages to your app.</p>
        <Btn onClick={() => run(admin('subscribe'), 'Subscribed').then(() => check(['subscribed']))} busyText="Subscribing">Subscribe app</Btn>
      </Step>

      <Step k="i" title="Register the number on the Cloud API" c={ck.registered} onCheck={() => check(['registered'])}>
        <p>Pick a 6-digit PIN. It becomes the number's two-step verification PIN: write it down somewhere safe.</p>
        <Btn onClick={async () => {
          const pin = await promptDialog('6-digit PIN for this number', { placeholder: '123456', required: true });
          if (!pin) return;
          await run(admin('register', { pin: pin.trim() }), 'Number registered');
          await check(['registered']);
        }}>Register number</Btn>
      </Step>

      <Step k="j" title="Get the message templates approved" c={ck.templates} onCheck={() => check(['templates'])}>
        <p>The welcome and follow-up messages must be approved by Meta first (minutes, up to 24 hours). Review them in {L('#/whatsapp/templates', 'Templates')}, then submit.</p>
        <Btn onClick={() => run(admin('templates_submit'), 'Templates sent to Meta').then(() => check(['templates']))} busyText="Sending">Submit starter templates</Btn>
      </Step>

      <Step k="k" title="Test with your own phone" c={ck.test} onCheck={() => check(['test'])}>
        <TestSend numbers={settings?.test_numbers || []} onDone={() => check(['test'])} />
      </Step>

      <Step k="l" title="Go live" c={{ ok: !!settings?.enabled, detail: settings?.enabled ? (settings.test_mode ? 'Live in Test mode: only test numbers get messages.' : 'Live: every new lead gets a welcome.') : 'Turn on in Settings when every step above is done.' }}>
        <Btn onClick={() => navigate('whatsapp', 'settings')} disabled={!settings?.ready_to_go_live && !settings?.enabled}>Open Settings</Btn>
      </Step>
    </div>
  );
}

const mark = (step, ok, after) => run(rpc('api_wa_setup_mark', { p_step: step, p_ok: ok }), ok ? 'Marked done' : 'Marked not done').then(after);

function Step({ k, title, c, children, onCheck, manual, onMark, extra }) {
  const ok = !!c?.ok;
  return (
    <section className="glass-card p-4" style={{ borderLeft: `4px solid ${ok ? '#34C759' : c ? '#FF9500' : 'rgba(118,118,128,0.25)'}` }}>
      <div className="flex items-start gap-3">
        <span className="h-8 w-8 rounded-full inline-flex items-center justify-center text-sm font-bold shrink-0"
          style={{ background: ok ? '#34C759' : 'rgba(118,118,128,0.14)', color: ok ? '#fff' : '#3C3C43' }}>{ok ? <Icon name="check" size={16} strokeWidth={3} /> : k}</span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-semibold text-glass-primary">{title}</h3>{extra}
          </div>
          {c?.detail && <div className="text-sm mt-0.5" style={{ color: ok ? '#1E8E3E' : '#B25E00' }}>{c.detail}{c.at ? <span className="text-glass-secondary"> · {ago(c.at)}</span> : null}</div>}
          <div className="text-sm text-glass-primary space-y-2 mt-2">{children}</div>
          <div className="flex flex-wrap gap-2 mt-3">
            {onCheck && <Btn ghost onClick={onCheck} busyText="Checking"><Icon name="refresh" size={14} />Check now</Btn>}
            {manual && <Btn ghost onClick={() => onMark(!ok)}>{ok ? 'Mark not done' : 'Mark done'}</Btn>}
          </div>
        </div>
      </div>
    </section>
  );
}

function IdForm({ label, field, value, onSaved }) {
  const [v, setV] = useState(value || '');
  const dirty = v.replace(/\D/g, '') !== String(value || '');
  return (
    <Field label={label}>
      <div className="flex gap-2">
        <input className="glass-input flex-1 font-mono" inputMode="numeric" value={v} onChange={(e) => setV(e.target.value)} placeholder="Digits only" />
        <Btn disabled={!dirty || !v.trim()} onClick={() => run(rpc('api_wa_number_save', { p: { [field]: v } }), `${label} saved`).then(onSaved)}>Save</Btn>
      </div>
    </Field>
  );
}

function SecretForm({ name, label, saved, onSaved }) {
  const [v, setV] = useState('');
  return (
    <Field label={label} hint={saved ? `Saved, ends in …${saved.last4} · ${ago(saved.at)} ago. Paste a new one to replace it.` : 'Not saved yet'}>
      <div className="flex gap-2">
        <input className="glass-input flex-1 font-mono" type="password" autoComplete="off" value={v} onChange={(e) => setV(e.target.value)} placeholder={saved ? '••••••••' : 'Paste here'} />
        <Btn disabled={v.trim().length < 8} onClick={() => run(rpc('api_wa_secret_save', { p_name: name, p_value: v }), `${label} saved`).then((r) => { if (r) { setV(''); onSaved(); } })}>Save</Btn>
      </div>
    </Field>
  );
}

function GatewayForm({ value, onSaved }) {
  const [v, setV] = useState(value || '');
  return (
    <Field label="Gateway address (from wrangler deploy)">
      <div className="flex gap-2">
        <input className="glass-input flex-1 font-mono" value={v} onChange={(e) => setV(e.target.value)} placeholder="https://weone-wa-gateway.<you>.workers.dev" />
        <Btn disabled={v.trim() === (value || '')} onClick={() => run(rpc('api_wa_settings_save', { p: { gateway_url: v.trim() } }), 'Gateway saved').then(onSaved)}>Save</Btn>
      </div>
    </Field>
  );
}

function TestSend({ numbers, onDone }) {
  const [pick, setTo] = useState('');
  const to = numbers.includes(pick) ? pick : numbers[0] || '';
  const [brand, setBrand] = useState('aviation');
  if (!numbers.length) {
    return <p>First add your own number under {L('#/whatsapp/settings', 'Settings > Test numbers')}.</p>;
  }
  return (
    <div className="space-y-2">
      <p>Sends the welcome template to your phone. Tap a button on it: the bot should answer within seconds.</p>
      <div className="flex flex-col sm:flex-row gap-2">
        <select className="glass-input" value={to} onChange={(e) => setTo(e.target.value)}>{numbers.map((n) => <option key={n} value={n}>+{n}</option>)}</select>
        <select className="glass-input" value={brand} onChange={(e) => setBrand(e.target.value)}><option value="aviation">We One Aviation welcome</option><option value="charter">Book My Charter welcome</option></select>
        <Btn onClick={() => run(admin('test_welcome', { phone: to, brand }), 'Sent: check your phone').then((r) => { if (r) setTimeout(onDone, 8000); })} busyText="Sending">Send test welcome</Btn>
      </div>
    </div>
  );
}
