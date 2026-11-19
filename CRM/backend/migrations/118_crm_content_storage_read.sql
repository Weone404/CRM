-- 118: the content bucket's read policy (116) calls crm_private.ads_can_view(); signed-in users need EXECUTE on it,
-- otherwise every signed link for an ad picture or video fails and Content > Ad creatives shows empty previews.
GRANT EXECUTE ON FUNCTION crm_private.ads_can_view() TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '118') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
