-- 068: FlightBridge HIOX India mailbox: its password may be saved like the other keys.
-- COPY of nikkk07/FlightBridge-AI flightbridge/migrations/010_hiox_mailbox.sql (canonical). Do not edit here;
-- edit upstream and re-copy. sha256 of canonical file: b36a74cef1e92c0767f4610a285c8715e4d496e6a63a2f01a4b0d974f805115f
-- Applied automatically by the FlightBridge engine on start-up (flightbridge db.ensure_schema). Additive; schema 'flightbridge' only.

-- 010: a second mailbox for outreach, the HIOX India cPanel mailbox (partnership@weoneaviation.in), sent over SMTP and
-- read over IMAP. Its password is stored encrypted like the other keys; the address, server and the choice of sending
-- mailbox ("send_from": hostinger | hiox) live in system_setting 'integrations'.
ALTER TABLE flightbridge.integration_secret DROP CONSTRAINT IF EXISTS integration_secret_name_check;
ALTER TABLE flightbridge.integration_secret ADD CONSTRAINT integration_secret_name_check CHECK (name = ANY (ARRAY[
  'google_places_api_key', 'groq_api_key', 'gemini_api_key', 'hostinger_mail_api_token', 'hostinger_mailbox_resource_id',
  'tavily_api_key', 'hiox_mail_password']));
