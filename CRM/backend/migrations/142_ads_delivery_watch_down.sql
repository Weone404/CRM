-- Rollback of 142: the delivery watch goes; nothing else used it.
DROP FUNCTION IF EXISTS public.api_ads_delivery(), crm_private.ads_google_delivery();
