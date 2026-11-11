// Test-only entry: renders CRM > Amazon on its own against the local fake PostgREST (fake_api.mjs).
import React from 'react';
import { createRoot } from 'react-dom/client';
import '../../../../frontend/src/index.css';
import Amazon from '../../../../frontend/src/components/Amazon.jsx';
import { supabase } from '../../../../frontend/src/backend/supabaseClient';
import { PhoneApp, BusinessEmail } from '../../../../frontend/src/components/AppAlerts.jsx';
import { useRoute } from '../../../../frontend/src/utils/route';

function App() {
  const [access, setAccess] = React.useState(null);
  const [err, setErr] = React.useState('');
  const route = useRoute();
  React.useEffect(() => { supabase.rpc('api_amz_access').then(({ data, error }) => (error ? setErr(error.message) : setAccess(data))); }, []);
  if (err) return <div id="err">{err}</div>;
  if (!access) return <div>loading</div>;
  if (!access.can_view) return <div id="denied">No Amazon access</div>;
  // Same cards as the main CRM Settings tab (App.jsx).
  if (route.tab === 'settings') return <div className="p-4 max-w-5xl mx-auto space-y-4"><PhoneApp notifications={access.can_view} /><BusinessEmail /></div>;
  return <div className="p-4 max-w-5xl mx-auto"><Amazon access={access} /></div>;
}
createRoot(document.getElementById('root')).render(<App />);
