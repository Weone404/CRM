// Test-only entry: renders CRM > WhatsApp (#/whatsapp/...) and the lead-window panel against the local fake PostgREST.
import React from 'react';
import { createRoot } from 'react-dom/client';
import '../../../../frontend/src/index.css';
import '../../../../frontend/src/components/ui/apple.css';
import WhatsApp from '../../../../frontend/src/components/WhatsApp.jsx';
import LeadWhatsApp from '../../../../frontend/src/components/whatsapp/LeadWhatsApp.jsx';
import { supabase } from '../../../../frontend/src/backend/supabaseClient';

function App() {
  const [access, setAccess] = React.useState(null);
  const [err, setErr] = React.useState('');
  const [lead, setLead] = React.useState(new URLSearchParams(location.search).get('lead'));
  React.useEffect(() => { if (!location.hash) location.hash = '#/whatsapp/inbox'; }, []);
  React.useEffect(() => { supabase.rpc('api_wa_access').then(({ data, error }) => (error ? setErr(error.message) : setAccess(data))); }, []);
  if (err) return <div id="err">{err}</div>;
  if (!access) return <div>loading</div>;
  if (lead) return <div className="p-4 max-w-xl mx-auto"><LeadWhatsApp leadId={lead} /></div>;
  if (!access.can_view) return <div id="denied">No WhatsApp access</div>;
  return <div className="p-3 sm:p-4 max-w-7xl mx-auto"><WhatsApp access={access} /></div>;
}
createRoot(document.getElementById('root')).render(<App />);
