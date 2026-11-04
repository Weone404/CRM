-- 055: Settings > AI Integrations also shows keys saved in FlightBridge AI > Settings (status only, never the key).
-- Admin only. Returns the provider id used on the AI Integrations page, last 4 characters and the last test result.
CREATE OR REPLACE FUNCTION public.ai_integrations_fb_keys() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN
    RAISE EXCEPTION 'Only Admin can view AI integrations' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT json_agg(json_build_object(
      'provider', CASE s.name WHEN 'groq_api_key' THEN 'groq' WHEN 'gemini_api_key' THEN 'gemini'
                    WHEN 'google_places_api_key' THEN 'google_places' WHEN 'hostinger_mail_api_token' THEN 'hostinger_mail'
                    WHEN 'hostinger_mailbox_resource_id' THEN 'hostinger_mailbox' ELSE s.name END,
      'last4', s.last4, 'updated_at', s.updated_at, 'updated_by_name', e.name,
      'last_test_at', s.last_test_at, 'last_test_ok', s.last_test_ok, 'last_test_message', s.last_test_message)
      ORDER BY s.name)
    FROM flightbridge.integration_secret s LEFT JOIN public.employee e ON e.id = s.updated_by), '[]');
END $$;

REVOKE ALL ON FUNCTION public.ai_integrations_fb_keys() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ai_integrations_fb_keys() TO authenticated;
