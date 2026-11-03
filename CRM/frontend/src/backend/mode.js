// VITE_BACKEND=supabase switches the whole app to the Supabase backend.
// Anything else (or unset) keeps the Render backend exactly as before.
export const USE_SUPABASE = import.meta.env.VITE_BACKEND === 'supabase';
