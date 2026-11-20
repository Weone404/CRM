-- 120 Reel Studio posts the CRM's ad videos: SP01-SP11 (runs after 30_studio_tests.sql, which sets content_post_via = 'crm').
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
CREATE TEMP TABLE t_sp (k text PRIMARY KEY, id bigint);
GRANT ALL ON t_sp TO service_role, authenticated;
CREATE OR REPLACE FUNCTION pg_temp.p() RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM t_sp WHERE k = 'p' $$;
CREATE OR REPLACE FUNCTION pg_temp.save(p jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.api_content_item_save(p) $$;
CREATE OR REPLACE FUNCTION pg_temp.tasks() RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_agg(x), '[]') FROM jsonb_array_elements(public.svc_content_post_tasks()) x WHERE (x->>'id')::bigint = pg_temp.p() $$;
CREATE OR REPLACE FUNCTION pg_temp.row_() RETURNS public.content_item LANGUAGE sql AS $$ SELECT * FROM public.content_item WHERE id = pg_temp.p() $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;

DELETE FROM public.ads_config WHERE key = 'content_post_via';            -- the default: Reel Studio posts its own ad videos
SET ROLE service_role;
INSERT INTO t_sp SELECT 'p', (public.svc_content_adopt('{"studio_job": "6fdf67c1-sp", "title": "Pilot after 12th: check this first", "script": "12th ke baad pilot?\nFees se pehle ye check karo."}')->>'id')::bigint;
SELECT public.svc_content_video(pg_temp.p(), 'ad/' || pg_temp.p() || '/video.mp4', 'ad/' || pg_temp.p() || '/thumb.jpg', 32.3);
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT (x->>'via_studio')::boolean AND public.api_content_overview()->>'post_via' = 'studio'
                     FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x WHERE (x->>'id')::bigint = pg_temp.p()),
  'SP01 a Reel Studio ad video is marked as posted by Reel Studio');
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(pg_temp.tasks()) = 0, 'SP02a nothing goes to Reel Studio before it is approved and scheduled');
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.save(jsonb_build_object('action', 'approve', 'id', pg_temp.p()));
SELECT pg_temp.save(jsonb_build_object('action', 'caption', 'id', pg_temp.p(), 'caption', '12th ke baad pilot banna hai? Free career counselling. #pilottraining'));
SELECT pg_temp.save(jsonb_build_object('action', 'schedule', 'id', pg_temp.p(), 'post_at', now() + interval '3 hours'));
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT x->>'action' = 'schedule' AND x->>'studio_job' = '6fdf67c1-sp' AND (x->>'ai')::boolean AND x->>'caption' LIKE '12th ke baad%'
                          AND (x->>'post_at')::timestamptz > now() + interval '2 hours' AND length(x->>'sig') = 32 FROM jsonb_array_elements(pg_temp.tasks()) x),
  'SP02b approved and scheduled: Reel Studio gets the job, time, caption and AI label');
RESET ROLE;
UPDATE public.content_item SET post_at = now() - interval '1 minute' WHERE id = pg_temp.p();
SET ROLE service_role;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'post') x WHERE (x->>'id')::bigint = pg_temp.p()),
  'SP03 the CRM never posts it itself, even when its time has come');
RESET ROLE;
SELECT pg_temp.ok(NOT crm_private.content_ig_wake(), 'SP03b and the CRM''s posting clock stays asleep for it');
UPDATE public.content_item SET post_at = now() + interval '3 hours' WHERE id = pg_temp.p();

SET ROLE service_role;
SELECT pg_temp.ok((public.svc_content_post_ack(pg_temp.p(), 'not-the-sig', 'scheduled'))->>'stale' = 'true' AND jsonb_array_length(pg_temp.tasks()) = 1,
  'SP04a an answer for an older instruction does not count; the current one is still pending');
SELECT public.svc_content_post_ack(pg_temp.p(), pg_temp.tasks()->0->>'sig', 'scheduled');
SELECT pg_temp.ok(jsonb_array_length(pg_temp.tasks()) = 0 AND (pg_temp.row_()).ig->>'studio_state' = 'scheduled', 'SP04b once Reel Studio holds it, it is not sent again');
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.save(jsonb_build_object('action', 'caption', 'id', pg_temp.p(), 'caption', 'Pilot after 12th? Pehle ye check karo. Free counselling. #cpl'));
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT x->>'action' = 'schedule' AND x->>'caption' LIKE 'Pilot after 12th?%' FROM jsonb_array_elements(pg_temp.tasks()) x),
  'SP05 a new caption is sent again');
SELECT public.svc_content_post_ack(pg_temp.p(), pg_temp.tasks()->0->>'sig', 'scheduled');
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.save(jsonb_build_object('action', 'unschedule', 'id', pg_temp.p()));
RESET ROLE;
SET ROLE service_role;
SELECT pg_temp.ok((SELECT x->>'action' = 'cancel' FROM jsonb_array_elements(pg_temp.tasks()) x), 'SP06a unscheduled: Reel Studio is told to cancel it');
SELECT public.svc_content_post_ack(pg_temp.p(), NULL, 'cancelled');
SELECT pg_temp.ok(jsonb_array_length(pg_temp.tasks()) = 0 AND NOT (pg_temp.row_()).ig ? 'studio_state', 'SP06b cancelled once, then nothing more');
RESET ROLE;

-- scheduled again; Reel Studio posts it and reports the post id, link and numbers
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.save(jsonb_build_object('action', 'schedule', 'id', pg_temp.p(), 'post_at', now() + interval '1 hour'));
RESET ROLE;
SET ROLE service_role;
SELECT public.svc_content_post_ack(pg_temp.p(), pg_temp.tasks()->0->>'sig', 'scheduled');
SELECT public.svc_content_update(pg_temp.p(), '{"status": "ready", "note": "Approved; posts soon"}');
RESET ROLE;
SELECT pg_temp.ok((pg_temp.row_()).approved_at IS NOT NULL AND crm_private.content_stage(pg_temp.row_()) = 'approved' AND (pg_temp.row_()).post_at IS NOT NULL,
  'SP07a Reel Studio''s "ready" report does not undo the approval or the time');
SET ROLE service_role;
SELECT public.svc_content_update(pg_temp.p(), '{"status": "posted", "posted_at": "2026-11-21T08:00:00Z", "ig_media_id": "17960000000000002",
  "media": {"permalink": "https://www.instagram.com/reel/sp1/"}, "stats": {"views": 950, "likes": 61, "saves": 12, "comments": 4}}');
RESET ROLE;
SELECT pg_temp.ok((SELECT ig->>'media_id' = '17960000000000002' AND ig->>'permalink' = 'https://www.instagram.com/reel/sp1/' AND ig->>'via' = 'studio'
                          AND (ig->'stats'->>'views')::int = 950 AND (ig->>'ai')::boolean AND post_at IS NULL AND NOT ig ? 'studio_state'
                          AND crm_private.content_stage(i) = 'posted' FROM public.content_item i WHERE id = pg_temp.p())
  AND jsonb_array_length(pg_temp.tasks()) = 0,
  'SP07b posted by Reel Studio: the Ad studio shows it as Posted with its link, AI label and numbers');
SET ROLE service_role;
SELECT public.svc_content_update(pg_temp.p(), '{"status": "posted", "stats": {"views": 1400}}');
SELECT pg_temp.ok(((pg_temp.row_()).ig->'stats'->>'views')::int = 1400 AND ((pg_temp.row_()).ig->'stats'->>'likes')::int = 61
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'stats') x WHERE (x->>'id')::bigint = pg_temp.p()),
  'SP07c later numbers come from Reel Studio, never from the CRM''s own Instagram reads');
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((pg_temp.save(jsonb_build_object('action', 'use_in_ads', 'id', pg_temp.p(), 'strategy_id', 77, 'creative_key', 'v1')))->>'stage' IN ('in_ads', 'results'),
  'SP08 "Use in ads" takes the post Reel Studio made');
RESET ROLE;

-- a refused post comes back to the owner; a post already under way is not cancelled
SET ROLE service_role;
INSERT INTO t_sp SELECT 'q', (public.svc_content_adopt('{"studio_job": "96c70ae6-sp", "title": "Parents: 3 questions"}')->>'id')::bigint;
SELECT public.svc_content_video((SELECT id FROM t_sp WHERE k = 'q'), 'ad/' || (SELECT id FROM t_sp WHERE k = 'q') || '/video.mp4', 'ad/' || (SELECT id FROM t_sp WHERE k = 'q') || '/thumb.jpg', 30);
RESET ROLE;
UPDATE public.content_item SET approved_at = now(), post_at = now() + interval '1 hour', ig = '{"studio_state": "scheduled", "studio_sent": "x"}' WHERE id = (SELECT id FROM t_sp WHERE k = 'q');
SET ROLE service_role;
SELECT public.svc_content_update((SELECT id FROM t_sp WHERE k = 'q'), '{"status": "ready", "ig_error": "The video is too short"}');
SELECT pg_temp.ok((SELECT post_at IS NULL AND ig->>'error' = 'The video is too short' AND note LIKE 'Instagram did not take it%' AND NOT ig ? 'studio_state'
                     FROM public.content_item WHERE id = (SELECT id FROM t_sp WHERE k = 'q')),
  'SP09a a post Instagram refused comes back to the owner with the reason');
RESET ROLE;
UPDATE public.content_item SET post_at = NULL, ig = '{"studio_state": "scheduled", "studio_sent": "x"}' WHERE id = (SELECT id FROM t_sp WHERE k = 'q');
SET ROLE service_role;
SELECT public.svc_content_post_ack((SELECT id FROM t_sp WHERE k = 'q'), NULL, 'too_late');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_post_tasks()) x WHERE (x->>'id')::bigint = (SELECT id FROM t_sp WHERE k = 'q')),
  'SP09b already posting in Reel Studio: no endless cancel');
SELECT pg_temp.ok((public.svc_content_post_ack(pg_temp.p(), NULL, 'bogus'))->>'ok' = 'false', 'SP09c unknown answers are refused');
RESET ROLE;

-- switch back to the CRM posting itself
INSERT INTO public.ads_config (key, value) VALUES ('content_post_via', 'crm') ON CONFLICT (key) DO UPDATE SET value = 'crm';
UPDATE public.content_item SET post_at = now() - interval '1 minute', ig = '{}' WHERE id = (SELECT id FROM t_sp WHERE k = 'q');
SET ROLE service_role;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'post') x WHERE (x->>'id')::bigint = (SELECT id FROM t_sp WHERE k = 'q'))
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_post_tasks()) x WHERE (x->>'id')::bigint = (SELECT id FROM t_sp WHERE k = 'q')),
  'SP10 with content_post_via = crm the CRM posts it and Reel Studio is not asked');
RESET ROLE;
DELETE FROM public.ads_config WHERE key = 'content_post_via';

SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_content_post_tasks()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.svc_content_post_ack(bigint,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.svc_content_update(bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_content_overview(date)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.svc_content_post_tasks()', 'EXECUTE'),
  'SP11 the Reel Studio posting functions stay private');
DO $$ BEGIN RAISE NOTICE 'ALL STUDIO POSTING SQL CHECKS PASSED'; END $$;
