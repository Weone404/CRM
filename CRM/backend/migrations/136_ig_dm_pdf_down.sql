-- Down for 136: back to 135 (no brochure).
DO $$ BEGIN
  IF to_regprocedure('public.api_ig_dm_settings_save_v135(jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ig_dm_settings_save(jsonb);
    ALTER FUNCTION public.api_ig_dm_settings_save_v135(jsonb) RENAME TO api_ig_dm_settings_save;
  END IF;
  IF to_regprocedure('public.api_ig_dm_status_v135()') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ig_dm_status();
    ALTER FUNCTION public.api_ig_dm_status_v135() RENAME TO api_ig_dm_status;
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_settings_save(jsonb), public.api_ig_dm_status() TO authenticated;
UPDATE public.ads_config SET value = (value::jsonb - 'pdf_url' - 'pdf_name')::text, updated_at = now() WHERE key = 'ig_dm';
ALTER TABLE public.ig_dm_person DROP COLUMN IF EXISTS pdf_at;
UPDATE public.ads_config SET value = '135', updated_at = now() WHERE key = 'ads_schema' AND value = '136';
