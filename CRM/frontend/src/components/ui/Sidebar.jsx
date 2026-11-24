import Icon from '../icons';

// Sections grouped the way people think about them. Only sections this person may open are passed in.
export const NAV_GROUPS = [
  { id: 'home', label: '', ids: ['home'] },
  { id: 'people', label: 'People', ids: ['leads', 'students', 'tasks', 'team', 'attendance'] },
  { id: 'growth', label: 'Growth', ids: ['google', 'content', 'metaads', 'amazon', 'partnerships'] },
  { id: 'setup', label: 'Setup', ids: ['connections', 'settings', 'policy', 'profile', 'leave', 'account'] },
];

export function groupTabs(tabs) {
  const byId = new Map(tabs.map((t) => [t.id, t]));
  const seen = new Set();
  const groups = NAV_GROUPS.map((g) => {
    const items = g.ids.map((id) => byId.get(id)).filter(Boolean);
    items.forEach((t) => seen.add(t.id));
    return { ...g, items };
  });
  const rest = tabs.filter((t) => !seen.has(t.id));          // anything new lands at the end instead of vanishing
  if (rest.length) groups[groups.length - 1].items.push(...rest);
  return groups.filter((g) => g.items.length);
}

export default function Sidebar({ tabs, active, onSelect, badges = {}, footer }) {
  const groups = groupTabs(tabs);
  return (
    <nav aria-label="Main" className="crm-sidebar hidden lg:flex flex-col gap-5 px-3 py-4">
      {groups.map((g) => (
        <div key={g.id} className="flex flex-col gap-0.5">
          {g.label && <div className="px-3 pb-1.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-glass-secondary">{g.label}</div>}
          {g.items.map((t) => {
            const on = active === t.id;
            const badge = badges[t.id];
            return (
              <button key={t.id} type="button" onClick={() => onSelect(t.id)} aria-current={on ? 'page' : undefined}
                className={`crm-side-item ${on ? 'is-active' : ''}`}>
                <span className="flex items-center gap-2.5 min-w-0"><Icon name={t.icon} size={17} strokeWidth={on ? 2.2 : 1.8} /><span className="truncate">{t.label}</span></span>
                {badge ? <span className="crm-side-badge" aria-label={`${badge} need attention`}>{badge}</span> : null}
              </button>
            );
          })}
        </div>
      ))}
      {footer && <div className="mt-auto">{footer}</div>}
    </nav>
  );
}
