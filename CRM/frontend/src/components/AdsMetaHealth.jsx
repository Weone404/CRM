import Icon from './icons';
import { rpc, run, useLoad, Btn } from './adsKit';
import { showToast } from '../utils/toast';

// CRM > Meta Ads > Overview (migration 105): account health from Meta (Opportunity Score and recommendations, account
// status, delivery, pacing) and open warnings. Checked every 3 hours by ads-sync (meta_health); approvers can check now.

const C = { green: '#1E9E4A', red: '#D93025', amber: '#B25E00', blue: '#0088FF', grey: 'rgba(118,118,128,0.14)' };
const inr = (v) => (v === null || v === undefined ? '–' : `₹${Math.round(Number(v)).toLocaleString('en-IN')}`);
const ago = (t) => { const m = Math.round((Date.now() - new Date(t).getTime()) / 60000); return m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`; };

function Ring({ score }) {
  const v = Math.max(0, Math.min(100, Number(score) || 0)), r = 26, c = 2 * Math.PI * r;
  const col = v >= 80 ? C.green : v >= 50 ? C.amber : C.red;
  return (
    <svg width="68" height="68" viewBox="0 0 68 68" aria-label={`Opportunity Score ${score ?? 'not available'}`}>
      <circle cx="34" cy="34" r={r} fill="none" stroke={C.grey} strokeWidth="7" />
      {score !== null && score !== undefined && <circle cx="34" cy="34" r={r} fill="none" stroke={col} strokeWidth="7" strokeDasharray={`${(v / 100) * c} ${c}`} transform="rotate(-90 34 34)" strokeLinecap="round" />}
      <text x="34" y="39" textAnchor="middle" fontSize="16" fontWeight="700" fill="currentColor">{score ?? '–'}</text>
    </svg>);
}

export default function AdsMetaHealth({ access, edge }) {
  const [h, reload] = useLoad(() => rpc('api_ads_meta_health'), [], { refreshMs: 120000 });
  if (!h) return null;
  const d = h.latest?.data;
  const warnings = h.warnings || [];
  const check = async () => {
    const r = await edge({ jobs: ['meta_health'] }).catch((e) => ({ error: e.message }));
    const res = r?.results?.meta_health;
    showToast(res?.detail || r?.error || 'Checked', res?.status === 'error' || r?.error ? 'error' : 'success');
    reload();
  };
  return (
    <section className="glass-card p-4 space-y-3" data-testid="meta-health">
      <div className="flex items-start gap-3">
        <Ring score={d?.opportunity?.score} />
        <div className="flex-1">
          <h3 className="font-bold">Account health</h3>
          <div className="text-xs text-glass-muted">{d ? <>Opportunity Score from Meta (0-100: how many of Meta's recommendations are applied; a guide, not a verdict).
            {' '}{d.account?.status_text ? `Account: ${d.account.status_text}. ` : ''}Checked {ago(h.latest.taken_at)}.</>
            : 'Not checked yet. It runs every 3 hours once the database update (105) and functions are in place.'}</div>
        </div>
        {access.can_approve && <Btn ghost onClick={check}><Icon name="refresh" size={14} />Check now</Btn>}
      </div>
      {d && <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-sm">
        <div className="glass-card p-2"><div className="text-[11px] text-glass-muted">Spent today / daily budgets</div><b>{inr(d.pacing?.today_spend)} / {inr(d.pacing?.daily_budget)}</b></div>
        <div className="glass-card p-2"><div className="text-[11px] text-glass-muted">This month</div><b>{inr(d.month?.spend)} · {d.month?.leads ?? 0} leads</b></div>
        <div className="glass-card p-2"><div className="text-[11px] text-glass-muted">Cost per lead (3 d / 14 d)</div><b>{inr(d.pacing?.cpl_3d)} / {inr(d.pacing?.cpl_14d)}</b></div>
        <div className="glass-card p-2"><div className="text-[11px] text-glass-muted">Live: campaigns · ad sets · ads</div>
          <b>{d.delivery?.campaigns ?? 0} · {d.delivery?.adsets ?? 0} · {d.delivery?.ads ?? 0}</b>
          <div className="text-[11px]">{d.delivery?.learning?.learning ? `${d.delivery.learning.learning} learning · ` : ''}{d.delivery?.learning?.limited ? `${d.delivery.learning.limited} learning limited` : ''}</div></div>
        {d.account?.spend_cap ? <div className="glass-card p-2 col-span-2"><div className="text-[11px] text-glass-muted">Account spending limit</div>
          <b>{inr(d.account.amount_spent)} of {inr(d.account.spend_cap)}</b></div> : null}
      </div>}
      <div className="space-y-1.5" data-testid="meta-warnings">
        <div className="text-sm font-semibold">{warnings.length ? `Warnings (${warnings.length})` : 'No open warnings'}{h.resolved_7d ? <span className="text-xs text-glass-muted font-normal"> · {h.resolved_7d} fixed in the last 7 days</span> : null}</div>
        {warnings.map((w) => (
          <div key={w.id} className="flex items-start gap-2 text-sm rounded-xl p-2" style={{ background: w.severity === 'high' ? 'rgba(217,48,37,0.07)' : 'rgba(178,94,0,0.07)', opacity: w.dismissed ? 0.6 : 1 }}>
            <span style={{ color: w.severity === 'high' ? C.red : C.amber }}><Icon name="alert" size={16} /></span>
            <div className="flex-1"><b>{w.title}</b>{w.detail && <div className="text-xs">{w.detail}</div>}
              <div className="text-[11px] text-glass-muted">since {ago(w.first_seen)}{w.dismissed ? ' · dismissed' : ''}</div></div>
            {access.is_admin && !w.dismissed && <Btn ghost onClick={() => run(rpc('api_ads_meta_warning_dismiss', { p_id: w.id }).then(reload), 'Dismissed')}>Dismiss</Btn>}
          </div>))}
      </div>
      {(d?.opportunity?.recommendations || []).length > 0 && <details className="text-sm" data-testid="meta-recs"><summary className="cursor-pointer font-semibold">Meta's recommendations ({d.opportunity.recommendations.length})</summary>
        <div className="space-y-1.5 mt-2">{d.opportunity.recommendations.map((r, i) => (
          <div key={i} className="rounded-xl p-2" style={{ background: 'rgba(118,118,128,0.06)' }}>
            <b>{r.title}</b>{r.score_lift ? <span className="text-xs text-glass-muted"> · +{r.score_lift} score</span> : null}{r.lift ? <span className="text-xs" style={{ color: C.green }}> · {r.lift}</span> : null}
            {r.body && <div className="text-xs">{r.body}</div>}
            {r.url && <a className="text-xs underline" href={r.url} target="_blank" rel="noreferrer">Review in Ads Manager</a>}
          </div>))}
          <div className="text-[11px] text-glass-muted">Check each one against your CRM results (Reports → Leads and CRM results) before applying: Meta optimises for its own results, the CRM knows which leads joined.</div>
        </div></details>}
      {(d?.errors || []).length > 0 && <div className="text-[11px] text-glass-muted">Could not read: {d.errors.join('; ')}</div>}
    </section>);
}
