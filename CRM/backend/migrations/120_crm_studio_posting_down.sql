-- 120 down: back to 119 (the CRM posts every approved ad itself).
DROP FUNCTION IF EXISTS public.svc_content_post_tasks();
DROP FUNCTION IF EXISTS public.svc_content_post_ack(bigint, text, text, text);
DO $$
BEGIN
  IF to_regprocedure('public.svc_content_update_v119(bigint, jsonb)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.svc_content_update(bigint, jsonb);
    ALTER FUNCTION public.svc_content_update_v119(bigint, jsonb) RENAME TO svc_content_update;
  END IF;
  IF to_regprocedure('public.api_content_overview_v119(date)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_content_overview(date);
    ALTER FUNCTION public.api_content_overview_v119(date) RENAME TO api_content_overview;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.svc_content_ig_due() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'ig_user_id', nullif(crm_private.ads_cfg('meta_ig_user_id'), ''),
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'post', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'caption', coalesce(i.caption, crm_private.content_caption_default(i)),
               'ai', i.post_ai, 'video_path', i.media->>'video_path', 'thumb_path', i.media->>'thumb_path', 'path', i.media->>'path',
               'container', i.ig->>'container', 'tries', coalesce((i.ig->>'tries')::int, 0)) ORDER BY i.post_at), '[]')
               FROM (SELECT * FROM public.content_item WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                       AND coalesce((ig->>'tries')::int, 0) < 3 AND kind IN ('ad_image', 'ad_video') ORDER BY post_at LIMIT 3) i),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'media_id', i.ig->>'media_id', 'kind', i.kind)), '[]')
                FROM (SELECT * FROM public.content_item WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                        AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes' ORDER BY id LIMIT 12) i)) $$;

CREATE OR REPLACE FUNCTION crm_private.content_ig_wake() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.content_item WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                   AND coalesce((ig->>'tries')::int, 0) < 3)
      OR EXISTS (SELECT 1 FROM public.content_item WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                   AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes') $$;

DROP FUNCTION IF EXISTS crm_private.content_post_sig(public.content_item);
DROP FUNCTION IF EXISTS crm_private.content_via_studio(public.content_item);
UPDATE public.content_item SET ig = ig - 'studio_state' - 'studio_sent' - 'studio_at' WHERE ig ?| ARRAY['studio_state', 'studio_sent', 'studio_at'];
DELETE FROM public.ads_config WHERE key = 'content_post_via';
UPDATE public.ads_config SET value = '119', updated_at = now() WHERE key = 'ads_schema';
