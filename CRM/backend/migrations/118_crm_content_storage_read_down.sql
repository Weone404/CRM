REVOKE EXECUTE ON FUNCTION crm_private.ads_can_view() FROM authenticated;
UPDATE public.ads_config SET value = '117', updated_at = now() WHERE key = 'ads_schema';
