-- 117: video ads end to end.
--  * Reel Studio sends finished ad videos (and a cover picture) to Growth > Content > Ad creatives (source 'studio').
--  * The owner attaches a video to a strategy's video creative (its approved text and call to action stay as they are).
--  * "Use in Meta" uploads it to the ad account (ads-sync meta_video); Create in Meta then builds that video ad, paused,
--    like the picture ads. Without an attached video, a video creative is still skipped with the old message.
-- Re-runnable; down: 117_crm_ad_videos_down.sql.

ALTER TABLE public.content_item DROP CONSTRAINT IF EXISTS content_item_source_check;
ALTER TABLE public.content_item ADD CONSTRAINT content_item_source_check CHECK (source IN ('planner', 'manual', 'strategy', 'studio'));
CREATE UNIQUE INDEX IF NOT EXISTS ux_content_item_studio_job ON public.content_item (studio_job) WHERE source = 'studio' AND studio_job IS NOT NULL;

-- a video in the strategy's build record: {videos: {key: {id, thumb_hash, name, at}}}
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_video(p_id bigint, p_key text, p_video_id text, p_thumb_hash text, p_name text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_strategy SET build = jsonb_set(coalesce(build, '{}') || jsonb_build_object('videos', coalesce(build->'videos', '{}')),
      ARRAY['videos', left(p_key, 60)], jsonb_build_object('id', p_video_id, 'thumb_hash', p_thumb_hash, 'name', left(p_name, 120), 'at', now())),
      updated_at = now() WHERE id = p_id $$;

DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_meta_build_work_v116(bigint)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_build_work(bigint) RENAME TO svc_ads_meta_build_work_v116;
  END IF;
  IF to_regprocedure('public.api_content_item_save_v116(jsonb)') IS NULL THEN
    ALTER FUNCTION public.api_content_item_save(jsonb) RENAME TO api_content_item_save_v116;
  END IF;
  IF to_regprocedure('public.api_content_overview_v116(date)') IS NULL THEN
    ALTER FUNCTION public.api_content_overview(date) RENAME TO api_content_overview_v116;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w jsonb := public.svc_ads_meta_build_work_v116(p_id);
BEGIN
  IF w IS NULL THEN RETURN NULL; END IF;
  RETURN w || jsonb_build_object('videos', coalesce((SELECT build->'videos' FROM public.ads_meta_strategy WHERE id = p_id), '{}'));
END $$;

-- the video creatives an ad video can be attached to (latest version of each open strategy)
CREATE OR REPLACE FUNCTION crm_private.content_video_slots() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('strategy_id', s.id, 'strategy', s.title, 'approved', s.approved_version IS NOT NULL,
           'key', c->>'key', 'name', c->>'name', 'headline', c->>'headline', 'primary_text', c->>'primary_text',
           'has_video', coalesce(s.build->'videos', '{}') ? (c->>'key')) ORDER BY s.id DESC, c->>'key'), '[]')
    FROM public.ads_meta_strategy s
    JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id
         AND v.version = coalesce(s.approved_version, (SELECT max(version) FROM public.ads_meta_strategy_version x WHERE x.strategy_id = s.id))
    CROSS JOIN jsonb_array_elements(coalesce(v.plan->'creatives', '[]')) c
   WHERE s.status <> 'archived' AND c->>'format' = 'video' $$;

CREATE OR REPLACE FUNCTION public.api_content_overview(p_week date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_content_overview_v116(p_week);
BEGIN
  RETURN o || jsonb_build_object(
    'ad_creatives', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'source', i.source, 'title', i.title, 'brief', i.brief, 'status', i.status,
        'strategy_id', i.strategy_id, 'creative_key', i.creative_key, 'has_picture', i.media ? 'path', 'paths', coalesce(i.media->'paths', '{}'),
        'video', i.media->>'video', 'video_path', i.media->>'video_path', 'thumb_path', i.media->>'thumb_path', 'meta_video', i.media->>'meta_video',
        'note', i.note, 'updated_at', i.updated_at) ORDER BY i.id DESC), '[]')
      FROM (SELECT * FROM public.content_item WHERE kind IN ('ad_image', 'ad_video') ORDER BY id DESC LIMIT 40) i),
    'video_slots', crm_private.content_video_slots());
END $$;

CREATE OR REPLACE FUNCTION public.api_content_item_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item; sid bigint; k text;
BEGIN
  IF coalesce(p->>'action', '') <> 'attach' THEN RETURN public.api_content_item_save_v116(p); END IF;
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can change content' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO i FROM public.content_item WHERE id = (p->>'id')::bigint FOR UPDATE;
  IF i.id IS NULL OR i.kind <> 'ad_video' THEN RAISE EXCEPTION 'Pick an ad video' USING ERRCODE = 'PT404'; END IF;
  IF p->>'strategy_id' IS NULL THEN                    -- detach
    UPDATE public.content_item SET strategy_id = NULL, creative_key = NULL, updated_at = now() WHERE id = i.id;
    RETURN jsonb_build_object('id', i.id);
  END IF;
  sid := (p->>'strategy_id')::bigint; k := p->>'creative_key';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(crm_private.content_video_slots()) x
                  WHERE (x->>'strategy_id')::bigint = sid AND x->>'key' = k) THEN
    RAISE EXCEPTION 'That strategy has no video creative "%"', left(coalesce(k, ''), 40) USING ERRCODE = 'PT422';
  END IF;
  -- one video per creative: a newer choice replaces the older one
  UPDATE public.content_item SET strategy_id = NULL, creative_key = NULL, updated_at = now()
   WHERE strategy_id = sid AND creative_key = k AND kind = 'ad_video' AND id <> i.id;
  UPDATE public.content_item SET strategy_id = sid, creative_key = k, media = media - 'meta_video', updated_at = now() WHERE id = i.id;
  RETURN jsonb_build_object('id', i.id);
END $$;

-- Reel Studio: a finished ad video made outside the weekly plan becomes an Ad creatives item (once per Reel Studio job)
CREATE OR REPLACE FUNCTION public.svc_content_adopt(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rid bigint; j text := left(p->>'studio_job', 80);
BEGIN
  IF j IS NULL OR length(coalesce(p->>'title', '')) < 3 THEN RETURN jsonb_build_object('ok', false, 'detail', 'studio_job and title are required'); END IF;
  SELECT id INTO rid FROM public.content_item WHERE source = 'studio' AND studio_job = j;
  IF rid IS NULL THEN
    INSERT INTO public.content_item (kind, source, title, brief, status, studio_job, slot)
    VALUES ('ad_video', 'studio', left(p->>'title', 120),
            jsonb_build_object('script', left(coalesce(p->>'script', ''), 3000), 'visual_brief', left(coalesce(p->>'summary', ''), 600)),
            'producing', j, now()) RETURNING id INTO rid;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', rid);
END $$;

-- Reel Studio: the ad video and its cover picture are in the content bucket
CREATE OR REPLACE FUNCTION public.svc_content_video(p_id bigint, p_video text, p_thumb text, p_seconds numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item;
BEGIN
  SELECT * INTO i FROM public.content_item WHERE id = p_id FOR UPDATE;
  IF i.id IS NULL OR i.kind <> 'ad_video' THEN RETURN jsonb_build_object('ok', false, 'detail', 'not an ad video'); END IF;
  IF p_video !~ ('^ad/' || p_id || '/video\.mp4$') OR p_thumb !~ ('^ad/' || p_id || '/thumb\.jpg$') THEN
    RETURN jsonb_build_object('ok', false, 'detail', 'bad path');
  END IF;
  UPDATE public.content_item SET media = (media - 'meta_video') || jsonb_build_object('video_path', p_video, 'thumb_path', p_thumb, 'path', p_thumb,
      'seconds', p_seconds), status = 'ready', note = NULL, updated_at = now() WHERE id = i.id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ads-sync: what meta_video needs, and its result
CREATE OR REPLACE FUNCTION public.svc_content_video_get(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', id, 'title', title, 'strategy_id', strategy_id, 'creative_key', creative_key,
         'video_path', media->>'video_path', 'thumb_path', media->>'thumb_path')
    FROM public.content_item WHERE id = p_id AND kind = 'ad_video' $$;
CREATE OR REPLACE FUNCTION public.svc_content_video_meta(p_id bigint, p_video_id text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.content_item SET media = media || jsonb_build_object('meta_video', p_video_id, 'meta_at', now()), updated_at = now() WHERE id = p_id $$;

REVOKE ALL ON FUNCTION public.svc_ads_meta_build_video(bigint, text, text, text, text), public.svc_ads_meta_build_work(bigint), public.svc_content_adopt(jsonb),
  public.svc_content_video(bigint, text, text, numeric), public.svc_content_video_get(bigint), public.svc_content_video_meta(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_build_video(bigint, text, text, text, text), public.svc_ads_meta_build_work(bigint), public.svc_content_adopt(jsonb),
  public.svc_content_video(bigint, text, text, numeric), public.svc_content_video_get(bigint), public.svc_content_video_meta(bigint, text) TO service_role;
REVOKE ALL ON FUNCTION crm_private.content_video_slots() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_content_overview(date), public.api_content_item_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_content_overview(date), public.api_content_item_save(jsonb) TO authenticated;

-- ad videos are bigger than pictures: the content bucket takes up to 50 MB files (the project's own cap still applies)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'file_size_limit') THEN
    EXECUTE $u$UPDATE storage.buckets SET file_size_limit = 52428800 WHERE id = 'content'$u$;
  END IF;
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '117')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
