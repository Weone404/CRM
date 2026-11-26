// "Today" on the Leads page: every call and demo due today (and anything overdue), for website, JustDial, walk-in,
// Meta and Google leads together. Tap a row to open the lead; Call dials; Done clears a call.
import { useEffect, useState } from 'react';
import Icon from '../icons';
import { rpc } from '../adsKit';
import { showToast } from '../../utils/toast';
import { displayPhone } from '../../utils/formatters';
import { whenIso } from '../../utils/leadPlan';
import './leads.css';

export default function TodayCard({ leads, segment, refreshKey, onOpenLead, onOpenAds, onCount }) {
  const [items, setItems] = useState(null);
  const [all, setAll] = useState(false);
  const load = () => rpc('api_leads_today').then(setItems, () => setItems([]));
  useEffect(() => { load(); }, [refreshKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const byId = new Map((leads || []).map((l) => [l.id, l]));
  const mine = (items || []).filter((x) => (x.kind === 'ads' ? segment === 'aviation' : (byId.get(x.lead_id)?.segment || 'aviation') === segment));
  useEffect(() => { onCount?.(mine.length); }, [mine.length]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!items || !mine.length) return null;
  const overdue = mine.filter((x) => x.overdue).length;
  const shown = all ? mine : mine.slice(0, 5);
  const open = (x) => (x.kind === 'ads' ? onOpenAds(x.lead_id) : byId.get(x.lead_id) && onOpenLead(byId.get(x.lead_id)));
  const done = async (e, x) => {
    e.stopPropagation();
    try { await rpc('api_lead_ws_followup_done', { p_followup: x.id }); showToast(`${x.name}: call done`, 'success'); load(); }
    catch (err) { showToast(err.message, 'error'); }
  };
  return (
    <div id="lead-followups" className="lp-section mb-4">
      <header className="flex items-center gap-2.5 mb-2">
        <span className="lp-ico" style={{ background: 'rgba(255,149,0,0.14)', color: '#FF9500' }}><Icon name="calendar" size={16} /></span>
        <div className="flex-1 min-w-0">
          <h3 className="text-[15px] font-semibold text-glass-primary">Today</h3>
          <p className="text-[12px] text-glass-muted">{mine.length} to do{overdue ? ` · ${overdue} overdue` : ''}</p>
        </div>
      </header>
      <ul className="divide-y" style={{ borderColor: 'rgba(60,60,67,0.12)' }}>
        {shown.map((x) => (
          <li key={`${x.type}-${x.id}`}>
            <div role="button" tabIndex={0} onClick={() => open(x)} onKeyDown={(e) => { if (e.key === 'Enter') open(x); }}
              className="flex items-center gap-3 py-2.5 cursor-pointer rounded-xl hover:bg-black/[0.03] px-1">
              <span className="lp-ico" style={x.type === 'demo' ? { background: 'rgba(52,199,89,0.14)', color: '#1E7B34' } : { background: 'rgba(0,122,255,0.1)', color: '#007AFF' }}>
                <Icon name={x.type === 'demo' ? 'students' : 'phone'} size={15} />
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-[14px] font-semibold text-glass-primary truncate">{x.name}{x.kind === 'ads' && <span className="ml-1.5 text-[11px] font-medium text-glass-muted">Meta/Google</span>}</div>
                <div className="text-[12px] truncate" style={{ color: x.overdue ? '#C4261D' : '#6E6E73' }}>
                  {x.type === 'demo' ? `Demo ${x.mode === 'online' ? 'online' : 'at the institute'}` : 'Call'} · {whenIso(x.at, x.has_time)}{x.overdue ? ' (overdue)' : ''}{x.detail ? ` · ${x.detail}` : ''}{x.owner ? ` · ${x.owner}` : ''}
                </div>
              </div>
              {x.type === 'demo' && x.meet_link && <a href={x.meet_link} target="_blank" rel="noreferrer noopener" onClick={(e) => e.stopPropagation()} className="lp-btn lp-btn-sm lp-btn-green">Join</a>}
              {x.phone && <a href={`tel:${String(x.phone).replace(/[^\d+]/g, '')}`} onClick={(e) => e.stopPropagation()} className="lp-btn lp-btn-sm lp-btn-soft" aria-label={`Call ${x.name} ${displayPhone(x.phone)}`}><Icon name="phone" size={14} /></a>}
              {x.type === 'call' && <button type="button" className="lp-btn lp-btn-sm lp-btn-soft" onClick={(e) => done(e, x)}>Done</button>}
            </div>
          </li>
        ))}
      </ul>
      {mine.length > 5 && <button type="button" className="lp-link mt-1" onClick={() => setAll(!all)}>{all ? 'Show less' : `Show all ${mine.length}`}</button>}
    </div>
  );
}
