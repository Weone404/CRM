-- 123 down
DROP FUNCTION IF EXISTS public.svc_content_dm_lead(jsonb);
UPDATE public.ads_config SET value = '122', updated_at = now() WHERE key = 'ads_schema';
