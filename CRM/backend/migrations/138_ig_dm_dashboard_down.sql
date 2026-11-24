DROP FUNCTION IF EXISTS public.api_ig_dm_dashboard(int);
ALTER TABLE public.ig_dm_person DROP COLUMN IF EXISTS follows;
ALTER TABLE public.ig_dm_log DROP COLUMN IF EXISTS permalink;
DROP TABLE IF EXISTS public.ig_dm_event;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '137') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
