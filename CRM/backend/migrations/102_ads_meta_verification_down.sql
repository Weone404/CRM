-- Undo 102_ads_meta_verification.sql (step 10 then needs a TEST code again).
DROP FUNCTION IF EXISTS public.svc_ads_meta_verification_lead();
UPDATE public.ads_config SET value = '101', updated_at = now() WHERE key = 'ads_schema';
