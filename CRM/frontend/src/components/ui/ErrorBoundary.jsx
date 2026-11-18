import { Component } from 'react';
import Icon from '../icons';

// One section crashing must never blank the whole CRM. This catches it, keeps the sidebar and every other
// section working, and offers a one-tap retry. A section whose code file vanished after a new deploy
// ("Failed to fetch dynamically imported module") is fixed by reloading the page, so that is the button then.
export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) { return { error }; }

  componentDidCatch(error, info) {
    console.error('[section crashed]', this.props.name || '', error, info?.componentStack);
  }

  componentDidUpdate(prev) {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null });
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    const stale = /dynamically imported module|Importing a module script failed|Failed to fetch/i.test(String(error?.message || error));
    return (
      <div role="alert" className="glass-card p-6 flex flex-col items-start gap-3 max-w-xl">
        <div className="inline-flex items-center gap-2 font-semibold text-glass-primary"><Icon name="alert" size={18} />
          {stale ? 'A newer version of the CRM is available' : `${this.props.name || 'This section'} hit a problem`}
        </div>
        <p className="text-sm text-glass-secondary m-0">
          {stale
            ? 'Reload to open this section with the latest version. Nothing you saved is lost.'
            : 'The rest of the CRM still works. Try this section again; if it keeps happening, tell the admin what you clicked.'}
        </p>
        <button type="button" className="glass-btn px-4 py-2 min-h-[40px] inline-flex items-center gap-2"
          onClick={() => (stale ? window.location.reload() : this.setState({ error: null }))}>
          <Icon name="refresh" size={16} />{stale ? 'Reload' : 'Try again'}
        </button>
      </div>
    );
  }
}
