-- 117 video ads: CV01-CV08 (runs after 10_content_tests.sql, which leaves strategy 77 with video creative v1).
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
CREATE OR REPLACE FUNCTION pg_temp.fails(p_sql text, p_like text, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN RAISE NOTICE 'PASS %', name; RETURN; END IF;
    RAISE EXCEPTION 'FAIL % (wrong error: %)', name, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL % (no error)', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

CREATE TEMP TABLE t_ids (k text PRIMARY KEY, id bigint);
GRANT ALL ON t_ids TO service_role, authenticated;
SET ROLE service_role;
INSERT INTO t_ids SELECT 'a', (public.svc_content_adopt('{"studio_job": "6fdf67c1", "title": "Pilot after 12th: check this first", "script": "12th ke baad pilot banna hai?"}')->>'id')::bigint;
INSERT INTO t_ids SELECT 'b', (public.svc_content_adopt('{"studio_job": "6fdf67c1", "title": "Pilot after 12th: check this first"}')->>'id')::bigint;
RESET ROLE;
SELECT pg_temp.ok((SELECT a.id = b.id FROM t_ids a, t_ids b WHERE a.k = 'a' AND b.k = 'b')
  AND (SELECT kind = 'ad_video' AND source = 'studio' AND status = 'producing' AND brief->>'script' LIKE '12th ke baad%' FROM public.content_item WHERE id = (SELECT id FROM t_ids WHERE k = 'a')),
  'CV01 a Reel Studio ad video arrives once (the same job never makes two items)');

SET ROLE service_role;
SELECT pg_temp.ok((public.svc_content_video((SELECT id FROM t_ids WHERE k = 'a'), 'ad/1/video.mp4', 'ad/1/thumb.jpg'))->>'detail' = 'bad path'
  AND (public.svc_content_video((SELECT id FROM t_ids WHERE k = 'a'), 'ad/' || (SELECT id FROM t_ids WHERE k = 'a') || '/video.mp4',
                                'ad/' || (SELECT id FROM t_ids WHERE k = 'a') || '/thumb.jpg', 27.4))->>'ok' = 'true', 'CV02 only its own video and cover paths are accepted');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'ready' AND media->>'video_path' LIKE 'ad/%/video.mp4' AND media->>'path' = media->>'thumb_path' AND (media->>'seconds')::numeric = 27.4
                     FROM public.content_item WHERE id = (SELECT id FROM t_ids WHERE k = 'a')), 'CV03 the video is ready with its cover as the preview');

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM jsonb_array_elements(public.api_content_overview()->'video_slots') x WHERE (x->>'strategy_id')::int = 77 AND x->>'key' = 'v1')
  AND (SELECT x->>'video_path' IS NOT NULL AND x->>'source' = 'studio' FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x WHERE (x->>'id')::bigint = (SELECT id FROM t_ids WHERE k = 'a')),
  'CV04 Ad creatives lists the video and the strategy video creatives it can go to');
SELECT public.api_content_item_save(jsonb_build_object('action', 'attach', 'id', (SELECT id FROM t_ids WHERE k = 'a'), 'strategy_id', 77, 'creative_key', 'v1'));
RESET ROLE;
SELECT pg_temp.ok((SELECT strategy_id = 77 AND creative_key = 'v1' FROM public.content_item WHERE id = (SELECT id FROM t_ids WHERE k = 'a'))
  AND (SELECT count(*) = 1 FROM public.content_item WHERE strategy_id = 77 AND creative_key = 'v1' AND kind = 'ad_video'),
  'CV05 attaching it to v1 replaces the video that was there (one video per creative)');
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_content_item_save(jsonb_build_object('action', 'attach', 'id', (SELECT id FROM t_ids WHERE k = 'a'), 'strategy_id', 77, 'creative_key', 'i1'))$q$,
  '%no video creative%', 'CV06 it cannot go to a picture creative');
RESET ROLE;
SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT public.api_content_item_save(jsonb_build_object('action', 'attach', 'id', (SELECT id FROM t_ids WHERE k = 'a'), 'strategy_id', null))$q$,
  '%Only Admin or ADS approvers%', 'CV07 viewers cannot attach or detach');
RESET ROLE;

-- ads-sync: the uploaded video lands in the strategy's build record, and Create in Meta sees it
SET ROLE service_role;
SELECT public.svc_ads_meta_build_video(77, 'v1', '9001', 'th1', 'Pilot after 12th');
SELECT public.svc_content_video_meta((SELECT id FROM t_ids WHERE k = 'a'), '9001');
RESET ROLE;
UPDATE public.ads_meta_strategy SET build = build || '{"status": "queued"}' WHERE id = 77;
SET ROLE service_role;
SELECT pg_temp.ok((public.svc_ads_meta_build_work(77))->'videos'->'v1'->>'id' = '9001' AND (public.svc_ads_meta_build_work(77))->'videos'->'v1'->>'thumb_hash' = 'th1'
  AND (public.svc_content_video_get((SELECT id FROM t_ids WHERE k = 'a')))->>'creative_key' = 'v1'
  AND NOT has_function_privilege('authenticated', 'public.svc_content_adopt(jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.svc_ads_meta_build_video(bigint,text,text,text,text)', 'EXECUTE'),
  'CV08 Create in Meta gets the video id and cover; the Reel Studio and Meta functions stay private');
RESET ROLE;
SELECT 'ALL VIDEO SQL CHECKS PASSED';
