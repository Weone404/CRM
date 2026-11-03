import { createClient } from '@supabase/supabase-js';

// Public values only: the project URL and the publishable (anon) key are meant to
// ship in the browser. Every table is protected by Row Level Security.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
export const SUPABASE_PUBLISHABLE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

export const supabase = SUPABASE_URL && SUPABASE_PUBLISHABLE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, storageKey: 'weone-crm-auth' },
    })
  : null;

export const AUTH_FUNCTION_URL = SUPABASE_URL ? `${SUPABASE_URL}/functions/v1/crm-auth` : '';
