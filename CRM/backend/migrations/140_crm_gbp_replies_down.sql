-- Rollback of 140: review replies. The reviews themselves (139) stay; replies already sent stay on Google.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-gbp-reviews', 'crm-gbp-reply');
  END IF;
END $$;
DROP TRIGGER IF EXISTS trg_gbp_review_changed ON public.gbp_review;
DROP FUNCTION IF EXISTS public.api_gbp_reply_status(), public.api_gbp_reply_settings_save(jsonb), public.api_gbp_reply_write(uuid, text, text, boolean),
  public.api_gbp_reply_action(bigint, text, text), public.api_gbp_reply_request(uuid, text, text),
  public.svc_gbp_reply_next(text[]), public.svc_gbp_reply_finish(bigint, boolean, jsonb, text), public.svc_gbp_reply_release(bigint),
  public.svc_gbp_reply_queue(int), public.svc_gbp_reply_result(bigint, text, text),
  crm_private.gbp_review_changed(), crm_private.gbp_reply_check(text, uuid, text), crm_private.gbp_reply_log(text, bigint, jsonb), crm_private.gbp_cfg(text, text);
DROP TABLE IF EXISTS public.gbp_reply, public.gbp_config;
-- the reviews list as it was in 139
CREATE OR REPLACE FUNCTION public.api_gbp_reviews(p_location uuid DEFAULT NULL, p_filter text DEFAULT 'all', p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.gbp_can_view() THEN RAISE EXCEPTION 'You do not have access to Google My Business' USING ERRCODE = 'PT403'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.created_at DESC NULLS LAST), '[]') FROM (
    SELECT r.review_id, r.location_id, coalesce(l.title, l.name) AS profile, r.reviewer, r.stars, r.comment, r.created_at, r.updated_at, r.reply, r.reply_at
      FROM public.gbp_review r JOIN public.gbp_location l ON l.id = r.location_id
     WHERE l.tracked AND (p_location IS NULL OR r.location_id = p_location)
       AND CASE coalesce(p_filter, 'all') WHEN 'unreplied' THEN r.reply IS NULL WHEN 'low' THEN r.stars <= 3 ELSE true END
     ORDER BY r.created_at DESC NULLS LAST LIMIT least(500, greatest(1, coalesce(p_limit, 100)))) z);
END $$;
