-- 123 Instagram DM leads: someone who comments on or messages the Instagram account and sends a phone number in the chat
-- becomes a lead in Leads (Reel Studio keeps the number; the office Mac sends it through crm-content dm_lead). Source
-- instagram / comment_dm or dm, campaign instagram_dm; the same phone is never filed twice (the website intake's dedup).
CREATE OR REPLACE FUNCTION public.svc_content_dm_lead(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE res jsonb; nm text := nullif(btrim(coalesce(p->>'name', '')), ''); u text := nullif(btrim(coalesce(p->>'username', '')), '');
BEGIN
  IF u IS NULL OR coalesce(p->>'phone', '') !~ '^\+91[6-9][0-9]{9}$' THEN RETURN jsonb_build_object('error', 'username and an Indian mobile are required'); END IF;
  res := crm_private.ingest_website_lead(jsonb_build_object(
    'name', coalesce(nm, '@' || u), 'phone', p->>'phone', 'course_interest', 'CPL (Instagram)',
    'utm_source', 'instagram', 'utm_medium', CASE WHEN p->>'source' = 'dm' THEN 'dm' ELSE 'comment_dm' END, 'utm_campaign', 'instagram_dm'));
  IF res->>'status' = 'created' THEN       -- who they are on Instagram and what they wrote, for the counsellor's call
    UPDATE public.lead SET last_note = left('Instagram @' || u || CASE WHEN nullif(p->>'text', '') IS NOT NULL THEN ': "' || (p->>'text') || '"' ELSE '' END, 400)
     WHERE id = (res->>'lead_id')::uuid;
  END IF;
  RETURN res;
END $$;
REVOKE ALL ON FUNCTION public.svc_content_dm_lead(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_content_dm_lead(jsonb) TO service_role;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '123') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
