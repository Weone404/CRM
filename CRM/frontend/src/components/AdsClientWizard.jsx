import { useEffect, useMemo, useState } from 'react';
import Icon from './icons';

// CRM > ADS > Clients: the 3-step client wizard and "Import existing accounts".
// Option lists (objectives, campaign types, special ad categories, bid strategies, industry presets) come from
// api_ads_options(), which mirrors Google's and Meta's own docs; the database rejects anything else.
// Currencies and time zones come from the browser's built-in lists (Intl), so they match the IANA / ISO names
// Google and Meta use. Nothing here talks to Google or Meta directly: discovery runs in the ads-sync Edge Function.

const ISO_COUNTRIES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ '
  + 'DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ '
  + 'LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW '
  + 'SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');
const safeList = (kind, fallback) => { try { return Intl.supportedValuesOf(kind); } catch { return fallback; } };
const CURRENCIES = safeList('currency', ['INR', 'USD', 'EUR', 'GBP', 'AED', 'AUD', 'CAD', 'SGD']);
// Browsers list some zones under older canonical names (e.g. Asia/Calcutta); Google, Meta and Postgres use Asia/Kolkata.
const TIMEZONES = [...new Set(['Asia/Kolkata', ...safeList('timeZone', ['UTC']).filter((z) => z !== 'Asia/Calcutta')])];
const tzOk = (z) => { try { new Intl.DateTimeFormat('en', { timeZone: z }); return true; } catch { return false; } };
const regionName = (() => { try { const d = new Intl.DisplayNames(['en'], { type: 'region' }); return (c) => d.of(c) || c; } catch { return (c) => c; } })();
const currencyName = (() => { try { const d = new Intl.DisplayNames(['en'], { type: 'currency' }); return (c) => d.of(c) || c; } catch { return (c) => c; } })();
const COUNTRY_OPTIONS = ISO_COUNTRIES.map((c) => ({ value: c, label: `${regionName(c)} (${c})` })).sort((a, b) => a.label.localeCompare(b.label));
export const URL_OK = (s) => !s || /^https?:\/\/[^\s/$.?#][^\s]*\.[a-z]{2,}/i.test(s.trim());

const Field = ({ label, children, hint, error, required }) => (
  <label className="block text-sm">
    <span className="block text-xs font-medium text-glass-secondary mb-1">{label}{required && <span style={{ color: '#C4261D' }}> *</span>}</span>
    {children}
    {error ? <span className="block text-[11px] mt-0.5" style={{ color: '#C4261D' }}>{error}</span>
      : hint && <span className="block text-[11px] text-glass-muted mt-0.5">{hint}</span>}
  </label>
);
// For a set of chips / checkboxes: a labelled group, not a <label> (a label around several controls breaks their names).
const Group = ({ label, children, hint, error, required }) => (
  <div role="group" aria-label={label} className="text-sm">
    <span className="block text-xs font-medium text-glass-secondary mb-1">{label}{required && <span style={{ color: '#C4261D' }}> *</span>}</span>
    {children}
    {error ? <span className="block text-[11px] mt-0.5" style={{ color: '#C4261D' }}>{error}</span>
      : hint && <span className="block text-[11px] text-glass-muted mt-0.5">{hint}</span>}
  </div>
);
const Input = (p) => <input {...p} className={`glass-input w-full px-3 py-2 text-sm ${p.className || ''}`} />;
const Select = ({ value, onChange, options, placeholder, ...p }) => (
  <select {...p} className="glass-input w-full px-3 py-2 text-sm" value={value || ''} onChange={(e) => onChange(e.target.value)}>
    <option value="">{placeholder || 'Choose…'}</option>
    {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
  </select>
);
// Searchable picker: type to filter (native datalist), value must be one of the options.
function Search({ id, value, onChange, options, placeholder, label }) {
  const shown = options.find((o) => o.value === value)?.label ?? value ?? '';
  const [text, setText] = useState(shown);
  useEffect(() => { setText(shown); }, [shown]);
  const pick = (t) => {
    setText(t);
    const hit = options.find((o) => o.label === t || o.value === t || o.value.toLowerCase() === t.trim().toLowerCase());
    onChange(hit ? hit.value : (t ? `?${t}` : ''));
  };
  return (
    <>
      <input list={id} aria-label={label} className="glass-input w-full px-3 py-2 text-sm" value={text} placeholder={placeholder}
        onChange={(e) => pick(e.target.value)} onBlur={() => { const hit = options.find((o) => o.value === value); if (hit) setText(hit.label); }} />
      <datalist id={id}>{options.map((o) => <option key={o.value} value={o.label} />)}</datalist>
    </>
  );
}
const Btn = ({ tone = '#007AFF', ghost, className = '', ...p }) => (
  <button type="button" {...p} className={`px-3 py-2 rounded-xl text-sm font-semibold min-h-[38px] inline-flex items-center gap-1.5 disabled:opacity-40 ${className}`}
    style={ghost ? { background: 'rgba(118,118,128,0.12)', color: '#1C1C1E' } : { background: tone, color: '#fff' }} />
);
const PlatformCard = ({ on, onClick, title, sub, logo }) => (
  <button type="button" onClick={onClick} aria-pressed={on} className="glass-card p-4 text-left flex items-start gap-3 w-full"
    style={on ? { boxShadow: 'inset 0 0 0 2px #007AFF' } : undefined}>
    <span className="h-10 w-10 rounded-xl inline-flex items-center justify-center font-bold text-white shrink-0" style={{ background: logo }}>{title[0]}</span>
    <span className="flex-1"><span className="block font-semibold">{title}</span><span className="block text-xs text-glass-secondary">{sub}</span></span>
    <span className="h-5 w-5 rounded-md inline-flex items-center justify-center" style={{ background: on ? '#007AFF' : 'rgba(118,118,128,0.18)', color: '#fff' }}>{on && <Icon name="check" size={14} />}</span>
  </button>
);
const Steps = ({ step }) => (
  <ol className="flex gap-2 text-xs" aria-label="Steps">
    {['Platforms', 'Business', 'Platform setup'].map((s, i) => (
      <li key={s} className="flex items-center gap-1.5" aria-current={step === i + 1 ? 'step' : undefined}>
        <span className="h-6 w-6 rounded-full inline-flex items-center justify-center font-bold"
          style={{ background: step >= i + 1 ? '#007AFF' : 'rgba(118,118,128,0.16)', color: step >= i + 1 ? '#fff' : '#6E6E73' }}>{i + 1}</span>
        <span className={step === i + 1 ? 'font-semibold' : 'text-glass-muted'}>{s}</span>{i < 2 && <span className="text-glass-muted">›</span>}
      </li>))}
  </ol>
);

const ECON_FIELDS = [
  ['target_cpl', 'Target cost per lead'], ['target_qualified_cpl', 'Target cost per qualified lead'], ['target_cac', 'Target cost per customer'],
  ['max_cac', 'Max acceptable cost per customer'], ['target_roas', 'Target ROAS (×)'], ['avg_order_value', 'Average order / fee value'],
  ['gross_margin_pct', 'Gross margin %'], ['ltv', 'Customer lifetime value'], ['sales_cycle_days', 'Sales cycle (days)'],
  ['monthly_budget', 'Monthly ad budget'], ['max_daily_budget', 'Max daily budget per campaign'],
];
const ABOUT_FIELDS = [['products', 'Products / services'], ['audience', 'Target audience'], ['geography', 'Target locations'],
  ['competitors', 'Competitors'], ['objectives', 'Business objectives'], ['brand_notes', 'Brand guidelines'], ['restrictions', 'Restrictions / claims to avoid']];

// Validation per step; returns {field: message}.
export function stepErrors(step, d, opts) {
  const e = {};
  if (step === 1 && !(d.platforms || []).length) e.platforms = 'Pick Google Ads, Meta or both.';
  if (step === 2) {
    if ((d.name || '').trim().length < 2) e.name = 'Enter the business name.';
    if (!URL_OK(d.website)) e.website = 'Use the full address, e.g. https://example.com';
    if (d.currency && !CURRENCIES.includes(d.currency)) e.currency = 'Pick a currency from the list.';
    if (d.timezone && (d.timezone.startsWith('?') || !tzOk(d.timezone))) e.timezone = 'Pick a time zone from the list.';
    if (d.country && !ISO_COUNTRIES.includes(d.country)) e.country = 'Pick a country from the list.';
  }
  if (step === 3) {
    const g = d.google_settings || {}, m = d.meta_settings || {};
    if ((d.platforms || []).includes('google')) {
      if (!g.objective) e.g_objective = 'Pick the campaign objective.';
      if (!(g.campaign_types || []).length) e.g_types = 'Pick at least one campaign type.';
    }
    if ((d.platforms || []).includes('meta')) {
      if (!m.objective) e.m_objective = 'Pick the campaign objective.';
      if (!(m.special_ad_categories || []).length) e.m_cats = 'Answer this (choose None if it does not apply).';
      if ((m.special_ad_categories || []).includes('ISSUES_ELECTIONS_POLITICS') && !m.special_ad_category_country) e.m_country = 'Pick the country these ads run in.';
    }
    ECON_FIELDS.forEach(([k]) => { if (d[k] !== '' && d[k] != null && !/^[0-9]+(\.[0-9]+)?$/.test(String(d[k]))) e[k] = 'A number of 0 or more.'; });
    if (Number(d.gross_margin_pct) > 100) e.gross_margin_pct = '0 to 100.';
  }
  void opts;
  return e;
}

// Applies an industry preset's starting choices, keeping anything the user already picked.
export function applyPreset(d, preset) {
  const x = preset?.extra || {};
  return {
    ...d, preset: preset?.value || '',
    google_settings: { ...(x.google || {}), ...Object.fromEntries(Object.entries(d.google_settings || {}).filter(([, v]) => v && (!Array.isArray(v) || v.length))) },
    meta_settings: { ...(x.meta || {}), ...Object.fromEntries(Object.entries(d.meta_settings || {}).filter(([, v]) => v && (!Array.isArray(v) || v.length))) },
  };
}

export function ClientWizard({ initial, options, onSave, onCancel, onImport }) {
  const [d, setD] = useState(() => ({ platforms: [], currency: 'INR', timezone: 'Asia/Kolkata', country: 'IN', google_settings: {}, meta_settings: {}, active: true, ...initial }));
  const [step, setStep] = useState(1);
  const [tried, setTried] = useState(false);
  const [more, setMore] = useState(false);
  const [targets, setTargets] = useState(ECON_FIELDS.some(([k]) => initial?.[k]));
  const [busy, setBusy] = useState(false);
  const errs = stepErrors(step, d, options);
  const ok = Object.keys(errs).length === 0;
  const set = (k, v) => setD((x) => ({ ...x, [k]: v }));
  const setG = (k, v) => setD((x) => ({ ...x, google_settings: { ...x.google_settings, [k]: v } }));
  const setM = (k, v) => setD((x) => ({ ...x, meta_settings: { ...x.meta_settings, [k]: v } }));
  const togglePlat = (p) => set('platforms', d.platforms.includes(p) ? d.platforms.filter((x) => x !== p) : [...d.platforms, p].sort());
  const presets = options?.['any.preset'] || [];
  const gTypes = options?.['google.campaign_type'] || [];
  const next = () => { setTried(true); if (ok) { setTried(false); setStep(step + 1); } };
  const save = async (draft) => {
    setTried(true);
    if (!draft && !ok) return;
    if (draft && (d.name || '').trim().length < 2) { setStep(2); return; }
    setBusy(true);
    const clean = (s) => Object.fromEntries(Object.entries(s || {}).filter(([, v]) => v !== '' && v != null));
    await onSave({ ...d, is_draft: draft, google_settings: clean(d.google_settings), meta_settings: clean(d.meta_settings),
      currency: d.currency?.startsWith('?') ? '' : d.currency, timezone: d.timezone?.startsWith('?') ? '' : d.timezone,
      country: d.country?.startsWith('?') ? '' : d.country });
    setBusy(false);
  };
  const E = (k) => (tried ? errs[k] : undefined);
  const g = d.google_settings, m = d.meta_settings;
  const cats = m.special_ad_categories || [];
  const toggleCat = (v) => setM('special_ad_categories', v === 'NONE' ? ['NONE'] : cats.includes(v) ? cats.filter((x) => x !== v) : [...cats.filter((x) => x !== 'NONE'), v]);

  return (
    <div className="glass-card p-4 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-bold">{d.id ? (d.is_draft ? `Finish setting up ${d.name}` : `Edit ${d.name}`) : 'New client'}</h3>
        <Steps step={step} />
      </div>

      {step === 1 && (
        <div className="space-y-3">
          <p className="text-sm text-glass-secondary">Where will this client advertise? Pick one or both; the next steps follow each platform's own setup.</p>
          <div className="grid sm:grid-cols-2 gap-3">
            <PlatformCard on={d.platforms.includes('google')} onClick={() => togglePlat('google')} title="Google Ads" sub="Search, Performance Max, YouTube, Display, Demand Gen, Shopping, App" logo="#1A73E8" />
            <PlatformCard on={d.platforms.includes('meta')} onClick={() => togglePlat('meta')} title="Meta" sub="Facebook, Instagram, Messenger, Audience Network" logo="#0866FF" />
          </div>
          {E('platforms') && <div className="text-xs" style={{ color: '#C4261D' }}>{E('platforms')}</div>}
          {!d.id && onImport && (
            <button type="button" onClick={onImport} className="text-sm font-semibold inline-flex items-center gap-1" style={{ color: 'var(--accent)' }}>
              Already running ads? Import existing accounts instead <Icon name="chevronRight" size={14} />
            </button>)}
        </div>
      )}

      {step === 2 && (
        <div className="space-y-3">
          <div className="grid sm:grid-cols-2 gap-3">
            <Field label="Business name" required error={E('name')}><Input value={d.name || ''} onChange={(e) => set('name', e.target.value)} /></Field>
            <Field label="Website" error={E('website') || (!URL_OK(d.website) ? 'Use the full address, e.g. https://example.com' : undefined)}>
              <Input type="url" inputMode="url" placeholder="https://" value={d.website || ''} onChange={(e) => set('website', e.target.value)} /></Field>
            <Field label="Industry" hint="Fills sensible starting choices in step 3. You can change every one.">
              <Select value={d.preset} options={presets} placeholder="Choose industry…" onChange={(v) => setD((x) => applyPreset(x, presets.find((p) => p.value === v)))} />
            </Field>
            <Field label="Country" error={E('country')}><Search id="ads-country" label="Country" value={d.country} onChange={(v) => set('country', v)} options={COUNTRY_OPTIONS} placeholder="Type to search" /></Field>
            <Field label="Currency" error={E('currency')} hint={d.id && d.platforms.length ? 'For imported accounts this comes from the ad account.' : 'Google Ads cannot change an account\'s currency later.'}>
              <Search id="ads-currency" label="Currency" value={d.currency} onChange={(v) => set('currency', v)} options={CURRENCIES.map((c) => ({ value: c, label: `${c} · ${currencyName(c)}` }))} placeholder="Type to search" />
            </Field>
            <Field label="Time zone" error={E('timezone')} hint="Reporting days follow this. Google Ads cannot change it later either.">
              <Search id="ads-tz" label="Time zone" value={d.timezone} onChange={(v) => set('timezone', v)} options={TIMEZONES.map((t) => ({ value: t, label: t }))} placeholder="Type to search" />
            </Field>
            <Field label="CRM leads" hint="Which leads in this CRM belong to this client. Leave as Not linked for clients whose leads are elsewhere.">
              <Select value={d.crm_segment} placeholder="Not linked" onChange={(v) => set('crm_segment', v)} options={[{ value: 'aviation', label: 'Aviation leads' }, { value: 'charter', label: 'Charter leads' }]} />
            </Field>
          </div>
          <button type="button" className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setMore(!more)} aria-expanded={more}>{more ? '−' : '+'} More about the business (optional)</button>
          {more && <div className="grid sm:grid-cols-2 gap-3">{ABOUT_FIELDS.map(([k, l]) => <Field key={k} label={l}><Input value={d[k] || ''} onChange={(e) => set(k, e.target.value)} /></Field>)}</div>}
        </div>
      )}

      {step === 3 && (
        <div className="space-y-4">
          {d.platforms.includes('google') && (
            <section className="rounded-2xl p-4 space-y-3" style={{ background: 'rgba(26,115,232,0.06)' }} aria-label="Google Ads setup">
              <h4 className="font-semibold">Google Ads</h4>
              <Field label="Campaign objective" required error={E('g_objective')} hint="As in Google Ads > New campaign.">
                <Select value={g.objective} options={options?.['google.objective'] || []} onChange={(v) => setD((x) => ({ ...x, google_settings: { ...x.google_settings, objective: v,
                  campaign_types: (x.google_settings.campaign_types || []).filter((t) => gTypes.find((o) => o.value === t)?.extra?.objectives?.includes(v)) } }))} />
              </Field>
              <Group label="Campaign types" required error={E('g_types')} hint={g.objective ? 'Only the types Google offers for this objective can be picked.' : 'Pick the objective first.'}>
                <div className="flex flex-wrap gap-2">
                  {gTypes.map((t) => {
                    const allowed = !!g.objective && t.extra?.objectives?.includes(g.objective);
                    const on = (g.campaign_types || []).includes(t.value);
                    return (
                      <button key={t.value} type="button" disabled={!allowed} aria-pressed={on}
                        onClick={() => setG('campaign_types', on ? g.campaign_types.filter((x) => x !== t.value) : [...(g.campaign_types || []), t.value])}
                        className="px-3 py-1.5 rounded-full text-sm disabled:opacity-35"
                        style={on ? { background: '#1A73E8', color: '#fff' } : { background: 'rgba(118,118,128,0.12)' }}>{t.label}</button>);
                  })}
                </div>
              </Group>
              <Field label="Bidding focus" hint="What Google's bidding optimises for.">
                <Select value={g.bidding} options={options?.['google.bidding'] || []} onChange={(v) => setG('bidding', v)} />
              </Field>
            </section>
          )}
          {d.platforms.includes('meta') && (
            <section className="rounded-2xl p-4 space-y-3" style={{ background: 'rgba(8,102,255,0.06)' }} aria-label="Meta setup">
              <h4 className="font-semibold">Meta</h4>
              <Field label="Campaign objective" required error={E('m_objective')} hint="As in Ads Manager > Create.">
                <Select value={m.objective} options={options?.['meta.objective'] || []} onChange={(v) => setM('objective', v)} />
              </Field>
              <Group label="Special ad categories" required error={E('m_cats')} hint="Meta requires this answer on every campaign. Pick all that apply.">
                <div className="space-y-1.5">
                  {(options?.['meta.special_ad_category'] || []).map((c) => (
                    <label key={c.value} className="flex items-start gap-2 text-sm">
                      <input type="checkbox" className="mt-0.5" checked={cats.includes(c.value)} onChange={() => toggleCat(c.value)} />
                      <span><span className="font-medium">{c.label}</span>{c.hint && <span className="block text-[11px] text-glass-muted">{c.hint}</span>}</span>
                    </label>))}
                </div>
              </Group>
              {cats.some((c) => c !== 'NONE') && (
                <div className="text-xs p-2 rounded-lg" style={{ background: 'rgba(255,149,0,0.12)', color: '#8A4B00' }}>
                  Meta limits targeting for these ads (for example age, gender and detailed audiences) and may review them more strictly.
                </div>)}
              {cats.some((c) => c !== 'NONE') && (
                <Field label="Country these ads run in" required={cats.includes('ISSUES_ELECTIONS_POLITICS')} error={E('m_country')}
                  hint={cats.includes('ISSUES_ELECTIONS_POLITICS') ? 'Must be a country where you and the Page are authorised.' : 'If empty, Meta uses your tax country.'}>
                  <Search id="ads-meta-country" label="Special ad category country" value={m.special_ad_category_country} onChange={(v) => setM('special_ad_category_country', v.startsWith('?') ? '' : v)} options={COUNTRY_OPTIONS} placeholder="Type to search" />
                </Field>)}
              <Field label="Bid strategy" hint="As in Ads Manager's campaign budget settings.">
                <Select value={m.bid_strategy} options={options?.['meta.bid_strategy'] || []} onChange={(v) => setM('bid_strategy', v)} />
              </Field>
            </section>
          )}
          <button type="button" className="text-sm font-semibold" style={{ color: 'var(--accent)' }} onClick={() => setTargets(!targets)} aria-expanded={targets}>{targets ? '−' : '+'} Targets and budget limits (optional)</button>
          {targets && (
            <div className="space-y-2">
              <p className="text-[11px] text-glass-muted">Leave empty if unknown; nothing is assumed. "Max daily budget per campaign" must be set before budget changes can be approved.</p>
              <div className="grid sm:grid-cols-3 gap-3">
                {ECON_FIELDS.map(([k, l]) => <Field key={k} label={`${l}${['gross_margin_pct', 'target_roas', 'sales_cycle_days'].includes(k) ? '' : d.currency && !d.currency.startsWith('?') ? ` (${d.currency})` : ''}`} error={E(k)}>
                  <Input inputMode="decimal" value={d[k] ?? ''} onChange={(e) => set(k, e.target.value)} /></Field>)}
              </div>
            </div>)}
        </div>
      )}

      <div className="flex flex-wrap gap-2 pt-1">
        {step > 1 && <Btn ghost onClick={() => { setTried(false); setStep(step - 1); }}><Icon name="chevronLeft" size={14} />Back</Btn>}
        <span className="flex-1" />
        <Btn ghost onClick={onCancel}>Cancel</Btn>
        {(d.name || '').trim().length >= 2 && <Btn ghost onClick={() => save(true)} disabled={busy}>Save draft</Btn>}
        {step < 3 ? <Btn onClick={next}>Next<Icon name="chevronRight" size={14} /></Btn>
          : <Btn tone="#248A3D" onClick={() => save(false)} disabled={busy}>{busy ? 'Saving…' : d.id ? 'Save client' : 'Create client'}</Btn>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Import existing accounts
export function ImportAccounts({ clients, options, discover, onImport, onCancel, goSettings }) {
  const [found, setFound] = useState(null);
  const [busy, setBusy] = useState(false);
  const [sel, setSel] = useState({});
  const [target, setTarget] = useState('new');
  const [name, setNameRaw] = useState('');
  const [nameTouched, setNameTouched] = useState(false);
  const setName = (v) => { setNameTouched(true); setNameRaw(v); };
  const [seg, setSeg] = useState('');
  const [preset, setPreset] = useState('');
  const find = async () => { setBusy(true); const r = await discover(); setBusy(false); if (r) setFound(r); };
  const known = useMemo(() => new Map((found?.known || []).map((k) => [`${k.platform}:${k.external_id}`, k.client])), [found]);
  const all = useMemo(() => ['google', 'meta'].flatMap((p) => found?.[p]?.accounts || []), [found]);
  const picked = all.filter((a) => sel[`${a.platform}:${a.external_id}`]);
  const firstName = picked[0]?.name || '';
  useEffect(() => { if (!nameTouched) setNameRaw(firstName); }, [firstName, nameTouched]);
  const go = async () => {
    setBusy(true);
    await onImport({ ...(target === 'new' ? { client: { name, crm_segment: seg || null, preset: preset || null } } : { client_id: target }),
      accounts: picked.map((a) => ({ platform: a.platform, external_id: a.external_id, name: a.name, currency: a.currency, timezone: a.timezone, login_customer_id: a.login_customer_id || null })) });
    setBusy(false);
  };
  const currencies = [...new Set(picked.map((a) => a.currency).filter(Boolean))];
  return (
    <div className="glass-card p-4 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-bold">Import existing accounts</h3>
        <Btn onClick={find} disabled={busy}><Icon name="search" size={14} />{busy && !found ? 'Looking…' : found ? 'Look again' : 'Find my accounts'}</Btn>
      </div>
      <p className="text-sm text-glass-secondary">Lists every Google Ads and Meta ad account the keys in Settings can open. Pick the ones that belong to one client; their name, currency and time zone come straight from Google / Meta. Nothing in the accounts is changed.</p>
      {found && ['google', 'meta'].map((p) => {
        const f = found[p];
        return (
          <section key={p} aria-label={p === 'google' ? 'Google Ads accounts' : 'Meta ad accounts'}>
            <h4 className="font-semibold text-sm mb-2">{p === 'google' ? 'Google Ads' : 'Meta'} <span className="text-glass-muted font-normal">({f.accounts.length})</span></h4>
            {f.error && <div className="text-xs mb-2 flex flex-wrap items-center gap-2" style={{ color: '#C4261D' }}>{f.error}{/not set/.test(f.error) && goSettings && <button type="button" className="underline" onClick={goSettings}>Open Settings</button>}</div>}
            {f.ok && f.accounts.length === 0 && <div className="text-xs text-glass-muted">No accounts found for these keys.</div>}
            <ul className="space-y-1">
              {f.accounts.map((a) => {
                const key = `${a.platform}:${a.external_id}`;
                const inCrm = known.get(key);
                return (
                  <li key={key}>
                    <label className={`flex flex-wrap items-center gap-2 text-sm p-2 rounded-xl ${inCrm ? 'opacity-50' : ''}`} style={{ background: sel[key] ? 'rgba(0,122,255,0.08)' : undefined }}>
                      <input type="checkbox" disabled={!!inCrm} checked={!!sel[key]} onChange={(e) => setSel({ ...sel, [key]: e.target.checked })} />
                      <span className="font-semibold">{a.name || '(no name)'}</span>
                      <span className="text-xs text-glass-muted">{a.platform === 'google' ? a.external_id.replace(/(\d{3})(\d{3})(\d{4})/, '$1-$2-$3') : `act_${a.external_id}`}</span>
                      <span className="text-xs text-glass-muted">{[a.currency, a.timezone, a.business].filter(Boolean).join(' · ')}</span>
                      <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full" style={a.active ? { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' } : { background: 'rgba(255,149,0,0.14)', color: '#B25E00' }}>{a.status}</span>
                      {a.login_customer_id && <span className="text-[11px] text-glass-muted">via manager {a.login_customer_id.replace(/(\d{3})(\d{3})(\d{4})/, '$1-$2-$3')}</span>}
                      {inCrm && <span className="text-[11px]">already in CRM ({inCrm})</span>}
                    </label>
                  </li>);
              })}
            </ul>
          </section>);
      })}
      {picked.length > 0 && (
        <div className="space-y-3 pt-2 border-t" style={{ borderColor: 'var(--border-subtle)' }}>
          {currencies.length > 1 && <div className="text-xs" style={{ color: '#B25E00' }}>These accounts use different currencies ({currencies.join(', ')}). Their spend will be shown separately, never added together.</div>}
          {picked.some((a) => !a.active) && <div className="text-xs" style={{ color: '#B25E00' }}>Some picked accounts are not active on the platform; they will import but may have no current data.</div>}
          <div className="grid sm:grid-cols-2 gap-3">
            <Field label="Add to">
              <Select value={target} placeholder="New client" onChange={(v) => setTarget(v || 'new')} options={[{ value: 'new', label: 'New client' }, ...(clients || []).map((c) => ({ value: c.id, label: c.name }))]} />
            </Field>
            {target === 'new' && <Field label="Client name" required error={name.trim().length < 2 ? 'Enter a name.' : undefined}><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>}
            {target === 'new' && <Field label="Industry"><Select value={preset} placeholder="Choose industry…" options={options?.['any.preset'] || []} onChange={setPreset} /></Field>}
            {target === 'new' && <Field label="CRM leads"><Select value={seg} placeholder="Not linked" onChange={setSeg} options={[{ value: 'aviation', label: 'Aviation leads' }, { value: 'charter', label: 'Charter leads' }]} /></Field>}
          </div>
          <div className="flex gap-2">
            <span className="flex-1" />
            <Btn ghost onClick={onCancel}>Cancel</Btn>
            <Btn tone="#248A3D" onClick={go} disabled={busy || (target === 'new' && name.trim().length < 2)}>{busy ? 'Importing…' : `Import ${picked.length} account${picked.length > 1 ? 's' : ''}`}</Btn>
          </div>
        </div>)}
      {!picked.length && <div className="flex justify-end"><Btn ghost onClick={onCancel}>Cancel</Btn></div>}
    </div>
  );
}
