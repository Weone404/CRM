DROP FUNCTION IF EXISTS public.api_ig_dm_settings_save(jsonb);
ALTER FUNCTION public.api_ig_dm_settings_save_v136(jsonb) RENAME TO api_ig_dm_settings_save;
CREATE OR REPLACE FUNCTION public.svc_ig_dm_cfg(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value)
  VALUES ('ig_dm', (coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}')
                    || (coalesce(p, '{}') - 'on' - 'message' - 'thanks' - 'public_reply' - 'public_replies' - 'cap' - 'inbox' - 'crm' - 'pdf_url' - 'pdf_name'))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;
REVOKE ALL ON FUNCTION public.api_ig_dm_settings_save(jsonb), public.svc_ig_dm_cfg(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_settings_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ig_dm_cfg(jsonb) TO service_role;
UPDATE public.ads_config SET value = '136', updated_at = now() WHERE key = 'ads_schema';
