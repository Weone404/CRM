-- 064: the Tavily web-search key can be saved (integration_secret only allowed the five older key names).
ALTER TABLE flightbridge.integration_secret DROP CONSTRAINT IF EXISTS integration_secret_name_check;
ALTER TABLE flightbridge.integration_secret ADD CONSTRAINT integration_secret_name_check CHECK (name = ANY (ARRAY[
  'google_places_api_key', 'groq_api_key', 'gemini_api_key', 'hostinger_mail_api_token', 'hostinger_mailbox_resource_id',
  'tavily_api_key']));
