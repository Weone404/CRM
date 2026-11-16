// Test-only entry: renders CRM > Google Ads (#/ads) or Meta Ads (#/metaads) on its own against the local fake PostgREST (fake_api.mjs).
import React from 'react';
import { createRoot } from 'react-dom/client';
import '../../../../frontend/src/index.css';
import Ads from '../../../../frontend/src/components/Ads.jsx';
import AdsMeta from '../../../../frontend/src/components/AdsMeta.jsx';
import { supabase } from '../../../../frontend/src/backend/supabaseClient';

function App() {
  const [access, setAccess] = React.useState(null);
  const [err, setErr] = React.useState('');
  const [meta, setMeta] = React.useState(location.hash.startsWith('#/metaads'));
  React.useEffect(() => { const f = () => setMeta(location.hash.startsWith('#/metaads')); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f); }, []);
  React.useEffect(() => { supabase.rpc('api_ads_access').then(({ data, error }) => (error ? setErr(error.message) : setAccess(data))); }, []);
  if (err) return <div id="err">{err}</div>;
  if (!access) return <div>loading</div>;
  if (!access.can_view) return <div id="denied">No ADS access</div>;
  return <div className="p-4 max-w-6xl mx-auto">{meta ? <AdsMeta access={access} /> : <Ads access={access} />}</div>;
}
createRoot(document.getElementById('root')).render(<App />);
