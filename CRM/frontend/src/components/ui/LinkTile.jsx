// A number or card that opens the list behind it. A real link: click to go, Cmd/Ctrl-click for a new browser tab,
// keyboard focusable. Lifts on hover, presses in on tap, and shows a chevron so it reads as tappable.
// to: [tab, section, params]   e.g. ['partnerships', 'pipeline', { stage: 'sent' }]
import { href } from '../../utils/route';

export default function LinkTile({ to, className = '', style, title, children, chevron = true, ...rest }) {
  if (!to) return <div className={className} style={style}>{children}</div>;
  return (
    <a href={href(...to)} className={`tile-link ${className}`} style={style} title={title} {...rest}>
      {children}
      {chevron && (
        <svg className="tile-link-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>
      )}
    </a>
  );
}

// An inline text link to another place (a school name, "see all").
export function GoLink({ to, className = '', style, children, ...rest }) {
  return <a href={href(...to)} className={`go-link ${className}`} style={style} {...rest}>{children}</a>;
}
