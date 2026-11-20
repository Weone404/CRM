-- 120 Reel Studio posts the CRM's ad videos; the CRM runs the ads on those posts.
--  * Reel Studio already has its own Instagram connection (Instagram Login). An approved and scheduled ad video that Reel
--    Studio made (it has a studio_job) is handed back to Reel Studio, which posts it at that time with the caption and the
--    AI info label set here, then reports the post id, link and numbers. The CRM's own posting (ads-sync ig_due, 119) skips
--    these, so nothing is posted twice and the CRM's Meta key needs no Instagram permission for them.
--  * "Use in ads" (119) then puts that post into a strategy's ad slot as before; Create in Meta makes the ad from the post.
--  * ads_config content_post_via = 'crm' switches back to the CRM posting everything itself (119 behaviour).
--  * Reel Studio pulls the work through crm-content: post_tasks (schedule / cancel) and post_ack. A task is resent when its
--    time, caption or label changes (the signature differs); a cancel is sent when it is unscheduled, unapproved or
--    removed while Reel Studio still holds it.
-- Wrapper-by-rename: svc_content_update (116) and api_content_overview (119) gain the new parts.

CREATE OR REPLACE FUNCTION crm_private.content_via_studio(i public.content_item) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(crm_private.ads_cfg('content_post_via'), 'studio') <> 'crm' AND i.kind = 'ad_video' AND coalesce(i.studio_job, '') <> '' $$;

-- what Reel Studio was last told; any change of time, caption or label means a new instruction
CREATE OR REPLACE FUNCTION crm_private.content_post_sig(i public.content_item) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT md5(coalesce(i.post_at::text, '') || '|' || coalesce(i.caption, crm_private.content_caption_default(i)) || '|' || i.post_ai::text) $$;

-- ------------------------------------------------------------------ Reel Studio (crm-content, service role)
CREATE OR REPLACE FUNCTION public.svc_content_post_tasks() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(t ORDER BY t->>'post_at' NULLS FIRST), '[]') FROM (
    SELECT jsonb_build_object('id', i.id, 'action', 'schedule', 'studio_job', i.studio_job, 'post_at', i.post_at,
             'caption', coalesce(i.caption, crm_private.content_caption_default(i)), 'ai', i.post_ai, 'sig', crm_private.content_post_sig(i)) t
      FROM public.content_item i
     WHERE crm_private.content_via_studio(i) AND NOT i.ig ? 'media_id' AND i.status <> 'skipped' AND i.approved_at IS NOT NULL
       AND i.post_at IS NOT NULL AND coalesce(i.ig->>'studio_state', '') <> 'posting'
       AND coalesce(i.ig->>'studio_sent', '') <> crm_private.content_post_sig(i)
    UNION ALL
    SELECT jsonb_build_object('id', i.id, 'action', 'cancel', 'studio_job', i.studio_job)
      FROM public.content_item i
     WHERE crm_private.content_via_studio(i) AND NOT i.ig ? 'media_id' AND i.ig->>'studio_state' = 'scheduled'
       AND (i.post_at IS NULL OR i.approved_at IS NULL OR i.status = 'skipped')
     LIMIT 20) x(t) $$;

-- Reel Studio's answer: scheduled (with the signature it acted on), cancelled, too_late (already posting) or failed
CREATE OR REPLACE FUNCTION public.svc_content_post_ack(p_id bigint, p_sig text, p_state text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item;
BEGIN
  SELECT * INTO i FROM public.content_item WHERE id = p_id FOR UPDATE;
  IF i.id IS NULL OR NOT crm_private.content_via_studio(i) THEN RETURN jsonb_build_object('ok', false, 'detail', 'not a Reel Studio ad video'); END IF;
  IF p_state = 'scheduled' THEN
    IF p_sig IS DISTINCT FROM crm_private.content_post_sig(i) THEN       -- changed in the meantime: the next task carries the new one
      RETURN jsonb_build_object('ok', true, 'stale', true);
    END IF;
    UPDATE public.content_item SET ig = (ig - 'error') || jsonb_build_object('studio_state', 'scheduled', 'studio_sent', p_sig, 'studio_at', now()),
      note = NULL, updated_at = now() WHERE id = i.id;
  ELSIF p_state = 'cancelled' THEN
    UPDATE public.content_item SET ig = ig - 'studio_state' - 'studio_sent', updated_at = now() WHERE id = i.id;
  ELSIF p_state = 'too_late' THEN
    UPDATE public.content_item SET ig = ig || jsonb_build_object('studio_state', 'posting'), updated_at = now() WHERE id = i.id;
  ELSIF p_state = 'failed' THEN
    UPDATE public.content_item SET ig = (ig - 'studio_state' - 'studio_sent') || jsonb_build_object('error', left(coalesce(p_note, 'Reel Studio could not post it'), 300)),
      post_at = NULL, note = left('Reel Studio: ' || coalesce(p_note, 'could not post it'), 300), updated_at = now() WHERE id = i.id;
  ELSE
    RETURN jsonb_build_object('ok', false, 'detail', 'state must be scheduled, cancelled, too_late or failed');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- reports from Reel Studio: the posted ad video's Instagram id, link and numbers land where the Ad studio reads them
DO $$
BEGIN
  IF to_regprocedure('public.svc_content_update_v119(bigint, jsonb)') IS NULL THEN
    ALTER FUNCTION public.svc_content_update(bigint, jsonb) RENAME TO svc_content_update_v119;
  END IF;
  IF to_regprocedure('public.api_content_overview_v119(date)') IS NULL THEN
    ALTER FUNCTION public.api_content_overview(date) RENAME TO api_content_overview_v119;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_content_update(p_id bigint, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; i public.content_item; st jsonb := '{}'; k text;
BEGIN
  SELECT * INTO i FROM public.content_item WHERE id = p_id;
  IF i.id IS NOT NULL AND crm_private.content_via_studio(i) AND p->>'status' IN ('producing', 'ready', 'held', 'failed', 'planned')
     AND (i.ig ? 'media_id' OR i.approved_at IS NOT NULL) THEN
    p := p - 'status';                                     -- an approved or posted ad keeps its place in the Ad studio
  END IF;
  r := public.svc_content_update_v119(p_id, p);
  IF i.id IS NULL OR NOT crm_private.content_via_studio(i) THEN RETURN r; END IF;
  FOREACH k IN ARRAY ARRAY['views', 'reach', 'likes', 'saves', 'shares', 'comments'] LOOP
    IF jsonb_typeof(p->'stats'->k) = 'number' THEN st := st || jsonb_build_object(k, (p->'stats'->>k)::bigint); END IF;
  END LOOP;
  IF coalesce(p->>'ig_media_id', '') ~ '^[0-9]{5,30}$' THEN
    UPDATE public.content_item SET ig = (ig - 'error' - 'studio_state' - 'studio_sent' - 'container') || jsonb_build_object(
        'media_id', p->>'ig_media_id', 'permalink', coalesce(p->'media'->>'permalink', ig->>'permalink'),
        'posted_at', coalesce(ig->>'posted_at', p->>'posted_at', now()::text), 'ai', i.post_ai, 'via', 'studio')
        || CASE WHEN st <> '{}' THEN jsonb_build_object('stats', coalesce(ig->'stats', '{}') || st, 'stats_at', now()) ELSE '{}' END,
      status = 'posted', post_at = NULL, updated_at = now() WHERE id = i.id;
  ELSIF i.ig ? 'media_id' AND st <> '{}' THEN
    UPDATE public.content_item SET ig = ig || jsonb_build_object('stats', coalesce(ig->'stats', '{}') || st, 'stats_at', now()) WHERE id = i.id;
  ELSIF coalesce(p->>'ig_error', '') <> '' AND NOT i.ig ? 'media_id' THEN
    UPDATE public.content_item SET ig = (ig - 'studio_state' - 'studio_sent') || jsonb_build_object('error', left(p->>'ig_error', 300)),
      post_at = NULL, note = left('Instagram did not take it: ' || (p->>'ig_error'), 300), updated_at = now() WHERE id = i.id;
  END IF;
  RETURN r;
END $$;

-- the CRM's own posting (ads-sync, 119) leaves Reel Studio's posts alone; their numbers come from Reel Studio
CREATE OR REPLACE FUNCTION public.svc_content_ig_due() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'ig_user_id', nullif(crm_private.ads_cfg('meta_ig_user_id'), ''),
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'post', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'caption', coalesce(i.caption, crm_private.content_caption_default(i)),
               'ai', i.post_ai, 'video_path', i.media->>'video_path', 'thumb_path', i.media->>'thumb_path', 'path', i.media->>'path',
               'container', i.ig->>'container', 'tries', coalesce((i.ig->>'tries')::int, 0)) ORDER BY i.post_at), '[]')
               FROM (SELECT * FROM public.content_item c WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                       AND coalesce((ig->>'tries')::int, 0) < 3 AND kind IN ('ad_image', 'ad_video') AND NOT crm_private.content_via_studio(c)
                     ORDER BY post_at LIMIT 3) i),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'media_id', i.ig->>'media_id', 'kind', i.kind)), '[]')
                FROM (SELECT * FROM public.content_item c WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                        AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes' AND coalesce(ig->>'via', '') <> 'studio'
                      ORDER BY id LIMIT 12) i)) $$;

CREATE OR REPLACE FUNCTION crm_private.content_ig_wake() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.content_item c WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                   AND coalesce((ig->>'tries')::int, 0) < 3 AND kind IN ('ad_image', 'ad_video') AND NOT crm_private.content_via_studio(c))
      OR EXISTS (SELECT 1 FROM public.content_item WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                   AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes' AND coalesce(ig->>'via', '') <> 'studio') $$;

-- the Ad studio shows which ads Reel Studio posts and whether it has taken the instruction
CREATE OR REPLACE FUNCTION public.api_content_overview(p_week date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_content_overview_v119(p_week);
BEGIN
  RETURN o || jsonb_build_object(
    'ad_creatives', (SELECT coalesce(jsonb_agg(e || jsonb_build_object('via_studio', coalesce(crm_private.content_via_studio(i), false),
                        'studio_state', i.ig->>'studio_state') ORDER BY n), '[]')
                       FROM jsonb_array_elements(coalesce(o->'ad_creatives', '[]')) WITH ORDINALITY a(e, n)
                       LEFT JOIN public.content_item i ON i.id = (e->>'id')::bigint),
    'post_via', CASE WHEN coalesce(crm_private.ads_cfg('content_post_via'), 'studio') = 'crm' THEN 'crm' ELSE 'studio' END);
END $$;

REVOKE ALL ON FUNCTION public.svc_content_post_tasks(), public.svc_content_post_ack(bigint, text, text, text), public.svc_content_update(bigint, jsonb),
  public.svc_content_update_v119(bigint, jsonb), public.svc_content_ig_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_content_post_tasks(), public.svc_content_post_ack(bigint, text, text, text), public.svc_content_update(bigint, jsonb),
  public.svc_content_update_v119(bigint, jsonb), public.svc_content_ig_due() TO service_role;
REVOKE ALL ON FUNCTION crm_private.content_via_studio(public.content_item), crm_private.content_post_sig(public.content_item) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_content_overview(date), public.api_content_overview_v119(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_content_overview(date) TO authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '120') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
