-- 119 Ad studio: ST01-ST12 (runs after 20_video_tests.sql: strategy 77 has video creative v1 and image creative i1).
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

CREATE TEMP TABLE t_st (k text PRIMARY KEY, id bigint);
GRANT ALL ON t_st TO service_role, authenticated;
CREATE OR REPLACE FUNCTION pg_temp.v() RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM t_st WHERE k = 'v' $$;
CREATE OR REPLACE FUNCTION pg_temp.save(p jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.api_content_item_save(p) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- these checks are the CRM posting itself (120 hands Reel Studio's own videos back to it unless content_post_via = crm)
INSERT INTO public.ads_config (key, value) VALUES ('content_post_via', 'crm') ON CONFLICT (key) DO UPDATE SET value = 'crm';

-- a fresh Reel Studio ad video with its file and cover
SET ROLE service_role;
INSERT INTO t_st SELECT 'v', (public.svc_content_adopt('{"studio_job": "96c70ae6", "title": "Parents: 3 questions before fees", "script": "Aapka bachcha pilot banna chahta hai?\nFees dene se pehle, ye teen sawaal poochhiye.\nEk: 12th mein Physics aur Maths hai?"}')->>'id')::bigint;
SELECT public.svc_content_video(pg_temp.v(), 'ad/' || pg_temp.v() || '/video.mp4', 'ad/' || pg_temp.v() || '/thumb.jpg', 30.1);
RESET ROLE;

SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT x->>'stage' = 'made' AND x->>'caption' LIKE 'Aapka bachcha pilot banna chahta hai? Fees dene%' AND x->>'caption' LIKE '%no commitment.'
                     FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x WHERE (x->>'id')::bigint = pg_temp.v()),
  'ST01 a finished ad shows as Made, with a first caption from its script and the counselling line');
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'schedule', 'id', pg_temp.v(), 'post_at', now() + interval '1 day'))$q$, '%Approve it first%',
  'ST02 nothing is scheduled before it is approved');
SELECT pg_temp.save(jsonb_build_object('action', 'approve', 'id', pg_temp.v()));
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'caption', 'id', pg_temp.v(), 'caption', 'short'))$q$, '%10-2,200 characters%', 'ST03a caption length checked');
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'caption', 'id', pg_temp.v(), 'caption', 'Tags ' || (SELECT string_agg('#t' || g, ' ') FROM generate_series(1, 31) g)))$q$,
  '%30 hashtags%', 'ST03b at most 30 hashtags (Instagram''s limit)');
SELECT pg_temp.save(jsonb_build_object('action', 'caption', 'id', pg_temp.v(), 'caption', 'Beta pilot banna chahta hai? Fees se pehle ye 3 sawaal. Free career counselling, no commitment. #pilottraining'));
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'schedule', 'id', pg_temp.v(), 'post_at', now() - interval '1 hour'))$q$, '%from now on%',
  'ST04a a time in the past is refused');
SELECT pg_temp.save(jsonb_build_object('action', 'schedule', 'id', pg_temp.v(), 'post_at', now() + interval '2 hours'));
RESET ROLE;
SELECT pg_temp.ok((SELECT approved_at IS NOT NULL AND post_ai AND post_at > now() AND caption LIKE 'Beta pilot%' AND crm_private.content_stage(i) = 'approved'
                     FROM public.content_item i WHERE id = pg_temp.v()) AND NOT crm_private.content_ig_wake(),
  'ST04b approved and scheduled: the AI info label is on by default for a Reel Studio video, and the clock stays asleep until it is due');

-- due: ads-sync gets it, makes the container, then publishes
UPDATE public.content_item SET post_at = now() - interval '1 minute' WHERE id = pg_temp.v();
SELECT pg_temp.ok(crm_private.content_ig_wake(), 'ST05a the clock wakes when a post is due');
SET ROLE service_role;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'post') x
                     WHERE (x->>'id')::bigint = pg_temp.v() AND (x->>'ai')::boolean AND x->>'video_path' LIKE 'ad/%/video.mp4' AND x->>'caption' LIKE 'Beta pilot%'),
  'ST05b at its time the post is handed to ads-sync with its file, caption and AI label');
SELECT public.svc_content_ig_step(pg_temp.v(), '{"container": "17890000000000001"}');
SELECT pg_temp.ok((public.svc_content_ig_due()->'post'->0->>'container') = '17890000000000001', 'ST06a a container still processing is picked up again (no second upload)');
SELECT public.svc_content_ig_step(pg_temp.v(), '{"media_id": "17950000000000001", "permalink": "https://www.instagram.com/reel/abc/", "ai": true}');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'posted' AND ig->>'media_id' = '17950000000000001' AND NOT ig ? 'container' AND crm_private.content_stage(i) = 'posted'
                     FROM public.content_item i WHERE id = pg_temp.v()), 'ST06b published: Posted, with its link');

-- a post Instagram keeps refusing stops after 3 tries and waits for the owner
SET ROLE service_role;
INSERT INTO t_st SELECT 'e', (public.svc_content_adopt('{"studio_job": "e3", "title": "Retry test ad"}')->>'id')::bigint;
SELECT public.svc_content_video((SELECT id FROM t_st WHERE k = 'e'), 'ad/' || (SELECT id FROM t_st WHERE k = 'e') || '/video.mp4', 'ad/' || (SELECT id FROM t_st WHERE k = 'e') || '/thumb.jpg', 20);
RESET ROLE;
UPDATE public.content_item SET approved_at = now(), post_at = now() - interval '1 minute' WHERE id = (SELECT id FROM t_st WHERE k = 'e');
SET ROLE service_role;
SELECT public.svc_content_ig_step((SELECT id FROM t_st WHERE k = 'e'), '{"error": "The video is too short"}') FROM generate_series(1, 3);
RESET ROLE;
SELECT pg_temp.ok((SELECT post_at IS NULL AND (ig->>'tries')::int = 3 AND note LIKE 'Instagram did not take it: The video is too short%' FROM public.content_item WHERE id = (SELECT id FROM t_st WHERE k = 'e'))
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'post') x WHERE (x->>'id')::bigint = (SELECT id FROM t_st WHERE k = 'e')),
  'ST06c after 3 refusals the post stops and the card says why');

-- numbers and comments every hour
SET ROLE service_role;
SELECT pg_temp.ok((SELECT count(*) = 1 FROM jsonb_array_elements(public.svc_content_ig_due()->'stats') x WHERE (x->>'id')::bigint = pg_temp.v()), 'ST07a posted items get their numbers read');
SELECT public.svc_content_ig_stats(pg_temp.v(), '{"views": 4210, "likes": 186, "saves": 41, "comments": 2, "bogus": "x"}',
  '[{"id": "18000000000000001", "username": "parent_delhi", "text": "Fees kitni hai?", "timestamp": "2026-11-20T10:00:00+0000"},
    {"id": "18000000000000002", "username": "rohit", "text": "Medical kahan hota hai?", "timestamp": "2026-11-20T11:00:00+0000"},
    {"id": "bad", "username": "x", "text": "y"}]');
SELECT public.svc_content_ig_stats(pg_temp.v(), '{"views": 4300}', '[{"id": "18000000000000001", "username": "parent_delhi", "text": "edited"}]');
RESET ROLE;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT (x->'ig'->'stats'->>'views')::int = 4300 AND (x->>'new_comments')::int = 2 FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x
                     WHERE (x->>'id')::bigint = pg_temp.v())
  AND (SELECT count(*) = 2 AND bool_and(body <> 'edited') FROM jsonb_array_elements(public.api_content_comments(pg_temp.v())) c, LATERAL (SELECT c->>'body' body) b),
  'ST07b views, likes, saves and two new comments show on the card; a comment is stored once');
SELECT pg_temp.save(jsonb_build_object('action', 'comments_seen', 'id', pg_temp.v()));
SELECT pg_temp.ok((SELECT (x->>'new_comments')::int = 0 FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x WHERE (x->>'id')::bigint = pg_temp.v()),
  'ST07c opening the comments clears the "new" count');

-- use in ads
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'use_in_ads', 'id', pg_temp.v(), 'strategy_id', 77, 'creative_key', 'i1'))$q$,
  '%no video ad%', 'ST08a a video cannot go into a picture ad');
RESET ROLE;
UPDATE public.ads_meta_strategy SET build = jsonb_set(build, '{steps}', '{"creative:v1:f1": {"id": "6001", "status": "done"}}') WHERE id = 77;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'use_in_ads', 'id', pg_temp.v(), 'strategy_id', 77, 'creative_key', 'v1'))$q$,
  '%already created in Meta%', 'ST08b an ad already created in Meta is not swapped underneath it');
RESET ROLE;
UPDATE public.ads_meta_strategy SET build = build - 'steps' WHERE id = 77;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.save(jsonb_build_object('action', 'use_in_ads', 'id', pg_temp.v(), 'strategy_id', 77, 'creative_key', 'v1'));
RESET ROLE;
SET ROLE service_role;
SELECT public.svc_content_ig_account('17841400000000001', 'we_one_aviation', NULL);
UPDATE public.ads_meta_strategy SET build = build || '{"status": "queued"}' WHERE id = 77;
SELECT pg_temp.ok((public.svc_ads_meta_build_work(77))->'posts'->'v1'->>'ig_media_id' = '17950000000000001'
  AND (public.svc_ads_meta_build_work(77))->>'ig_user_id' = '17841400000000001'
  AND (SELECT count(*) = 1 FROM public.content_item WHERE strategy_id = 77 AND creative_key = 'v1' AND kind = 'ad_video'),
  'ST09 "Use in ads" puts the Instagram post into the v1 slot (replacing the earlier video); Create in Meta gets the post and the account');
RESET ROLE;
SELECT pg_temp.ok((SELECT crm_private.content_stage(i) = 'in_ads' FROM public.content_item i WHERE id = pg_temp.v()), 'ST10a the card moves to In ads');

-- results: spend and leads of the ads made from it
INSERT INTO public.ads_clients (id, name) VALUES ('c1190000-0000-0000-0000-000000000119', 'Studio test') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status)
VALUES ('a1190000-0000-0000-0000-000000000119', 'c1190000-0000-0000-0000-000000000119', 'meta', '119119119', 'Studio test', 'INR', 'Asia/Kolkata', 'connected')
ON CONFLICT (platform, external_id) DO NOTHING;
UPDATE public.ads_meta_strategy SET build = jsonb_set(build, '{steps}', '{"campaign:c1": {"id": "7001"}, "ad:a1:v1": {"id": "8001"}}') WHERE id = 77;
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, leads) VALUES
  ((SELECT id FROM public.ads_accounts WHERE external_id = '119119119'), '8001', '7501', '7001', (now() AT TIME ZONE 'Asia/Kolkata')::date - 2, 1000, 5000, 80, 4),
  ((SELECT id FROM public.ads_accounts WHERE external_id = '119119119'), '8001', '7501', '7001', (now() AT TIME ZONE 'Asia/Kolkata')::date - 1, 840, 4200, 60, 3);
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT pg_temp.ok((SELECT x->>'stage' = 'results' AND (x->'results'->>'spend')::numeric = 1840 AND (x->'results'->>'leads')::int = 7 AND (x->'results'->>'cpl')::int = 263
                     FROM jsonb_array_elements(public.api_content_overview()->'ad_creatives') x WHERE (x->>'id')::bigint = pg_temp.v())
  AND (SELECT (c->>'learning_day')::int = 3 AND (c->>'spend')::numeric = 1840 AND (c->>'videos')::int = 1 AND (c->>'pictures')::int = 1
         FROM jsonb_array_elements(public.api_content_overview()->'campaigns') c WHERE (c->>'strategy_id')::int = 77),
  'ST10b Results: spend ₹1,840, 7 leads, ₹263 a lead; the campaign bar is on day 3 of the 7-day learning lock');
RESET ROLE;

SELECT pg_temp.as_('c'); SET ROLE authenticated;
SELECT pg_temp.fails($q$SELECT pg_temp.save(jsonb_build_object('action', 'approve', 'id', pg_temp.v()))$q$, '%Only Admin or ADS approvers%', 'ST11 viewers cannot approve, schedule or move ads');
RESET ROLE;
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_content_ig_due()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.svc_content_ig_step(bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_content_comments(bigint)', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'public.content_comment', 'SELECT'),
  'ST12 posting, numbers and comments functions stay private');
SELECT 'ALL STUDIO SQL CHECKS PASSED';
