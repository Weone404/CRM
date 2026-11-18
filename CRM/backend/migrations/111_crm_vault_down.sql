-- Undo 111: removes the Connections & keys overview. No key, token or log entry is touched.
DROP FUNCTION IF EXISTS public.api_vault_amz_remove(text);
DROP FUNCTION IF EXISTS public.api_vault_overview();
DROP FUNCTION IF EXISTS crm_private.vault_public_ids();
DROP FUNCTION IF EXISTS crm_private.vault_meta(text, boolean);
