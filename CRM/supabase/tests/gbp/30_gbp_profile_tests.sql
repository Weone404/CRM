-- 143 Google My Business: health check, posts, photos. PF01-PF45. Runs after 20_gbp_reply_tests.sql in the same database.
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
CREATE OR REPLACE FUNCTION pg_temp.q(p_sql text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE r text; BEGIN EXECUTE p_sql INTO r; RETURN r; END $$;
CREATE OR REPLACE FUNCTION pg_temp.x(p_sql text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN EXECUTE p_sql; END $$;
-- one check of the first profile's health, as "ok|detail"
CREATE OR REPLACE FUNCTION pg_temp.chk(p_key text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (c->>'ok') || '|' || (c->>'detail') FROM jsonb_array_elements(crm_private.gbp_health('a0000000-0000-4000-8000-000000000001')->'checks') c WHERE c->>'key' = p_key $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
\set L1 'a0000000-0000-4000-8000-000000000001'
\set L2 'a0000000-0000-4000-8000-000000000002'
\set C1 'c0000000-0000-4000-8000-000000000001'
DELETE FROM public.gbp_review WHERE location_id = :'L1';
UPDATE public.gbp_location SET phone = NULL, website = NULL, verified = NULL WHERE id = :'L1';

-- ---------------------------------------------------------------- who may do what
SET ROLE anon;
SELECT pg_temp.fails($q$SELECT public.api_gbp_profile()$q$, '%permission denied%', 'PF01 signed-out visitors cannot call the health check');
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_gbp_profile()$q$, '%not have access%', 'PF02 staff without access cannot see the health check');
SELECT pg_temp.fails($q$SELECT public.api_gbp_posts()$q$, '%not have access%', 'PF02b nor the posts');
SELECT pg_temp.fails($q$SELECT public.api_gbp_media()$q$, '%not have access%', 'PF02c nor the photos');
SELECT pg_temp.fails($q$SELECT public.svc_gbp_post_queue()$q$, '%permission denied%', 'PF02d no signed-in user can take posts from the send queue');
SELECT pg_temp.fails($q$SELECT public.svc_gbp_media_save(gen_random_uuid(), '[]')$q$, '%permission denied%', 'PF02e or write photos');
SELECT pg_temp.fails($q$SELECT * FROM public.gbp_post_out$q$, '%permission denied%', 'PF02f or read the tables');
SELECT pg_temp.as_('c');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'New batch starts on Monday.')$q$, :'L1'), '%Only Admin or approvers%', 'PF03 a viewer cannot publish a post');
SELECT pg_temp.ok((SELECT jsonb_array_length(p) = 1 AND p->0 @> '{"collected": false, "title": "We One Aviation", "ok": 1, "total": 4}' AND jsonb_array_length(p->0->'checks') = 4 FROM (SELECT public.api_gbp_profile() p) z),
  'PF04 before the detailed read: only what is already known is judged (4 checks), and it says the rest is not collected yet');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.chk('verified') LIKE 'false|Google has not confirmed%' AND pg_temp.chk('category') = 'true|Flight school' AND pg_temp.chk('phone') LIKE 'false|No phone number%' AND pg_temp.chk('website') LIKE 'false|No website link%',
  'PF05 verification unknown counts as not verified; missing phone and website are named');

-- ---------------------------------------------------------------- the detailed read
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_details_save(:'C1', jsonb_build_array(
  jsonb_build_object('name', 'locations/111', 'details', jsonb_build_object('description', repeat('We teach DGCA ground classes. ', 4), 'hours', jsonb_build_array(
      jsonb_build_object('d', 'MONDAY', 'o', '09:30', 'c', '18:00'), jsonb_build_object('d', 'MONDAY', 'o', '19:00', 'c', '21:00'), jsonb_build_object('d', 'TUESDAY', 'o', '09:30', 'c', '18:00')),
    'special_hours', 0, 'open_status', 'OPEN', 'more_categories', '[]'::jsonb, 'can_post', true, 'pending_edits', false, 'google_updated', true, 'review_uri', null, 'service_area', false)),
  jsonb_build_object('name', 'locations/999', 'details', '{}'::jsonb), jsonb_build_object('name', 'locations/222', 'details', 'not an object'), 'junk', NULL)) = 1
  AND public.svc_gbp_details_save(gen_random_uuid(), '[{"name": "locations/111", "details": {}}]') = 0 AND public.svc_gbp_details_save(:'C1', '{"a": 1}') = 0,
  'PF06 details are saved for the profiles of that login only; unknown profiles, other logins and junk change nothing');
RESET ROLE;
UPDATE public.gbp_location SET phone = '+91 98110 00000', website = 'http://weoneaviation.in', verified = true WHERE id = :'L1';
SELECT pg_temp.ok(pg_temp.chk('verified') LIKE 'true|%' AND pg_temp.chk('website') = 'false|The link does not start with https://: http://weoneaviation.in' AND pg_temp.chk('hours') = 'true|2 day(s) a week have hours.'
  AND pg_temp.chk('description') = 'true|119 of 750 characters used.' AND pg_temp.chk('description_full') LIKE 'false|Only 119 characters. Google allows 750%' AND pg_temp.chk('open') LIKE 'true|%'
  AND pg_temp.chk('google_updated') LIKE 'false|Google changed something on this profile%' AND pg_temp.chk('more_categories') LIKE 'false|None.%' AND pg_temp.chk('address') = 'true|Dwarka, New Delhi',
  'PF07 the checks read what Google has: http website, hours by day, description length, changes by Google waiting');
SELECT pg_temp.ok((SELECT h @> '{"collected": true, "total": 12, "ok": 8, "basic_missing": 2}' AND pg_temp.chk('photo_cover') IS NULL AND pg_temp.chk('reviews_answered') LIKE 'true|%' FROM (SELECT crm_private.gbp_health(:'L1') h) z),
  'PF08 the count of what is in order; photos and posts are not judged before they have been read');
UPDATE public.gbp_location SET website = 'https://weoneaviation.in/', details = details || '{"open_status": "CLOSED_TEMPORARILY", "google_updated": false, "more_categories": ["Aviation training institute"], "hours": "nonsense", "description": 12345}' WHERE id = :'L1';
SELECT pg_temp.ok(pg_temp.chk('website') = 'true|https://weoneaviation.in/' AND pg_temp.chk('open') = 'false|The profile says "temporarily closed".' AND pg_temp.chk('more_categories') = 'true|Aviation training institute'
  AND pg_temp.chk('hours') LIKE 'false|No opening hours%' AND pg_temp.chk('description') = 'true|5 of 750 characters used.' AND pg_temp.chk('google_updated') = 'true|Nothing to review.',
  'PF09 "temporarily closed" is flagged; odd data from Google (hours not a list, a number as description) does not break the check');
UPDATE public.gbp_location SET address = NULL, details = details || '{"open_status": "OPEN", "service_area": true}' WHERE id = :'L1';
SELECT pg_temp.ok(pg_temp.chk('address') = 'true|Service area set (no storefront address).', 'PF10 a business without a storefront passes with a service area');
INSERT INTO public.gbp_review (location_id, review_id, reviewer, stars, comment, created_at, reply) VALUES
  (:'L1', 'h1', 'A', 5, 'x', now() - interval '5 days', NULL), (:'L1', 'h2', 'B', 4, 'y', now() - interval '200 days', NULL), (:'L1', 'h3', 'C', 5, 'z', now() - interval '3 days', 'Thanks');
SELECT pg_temp.ok(pg_temp.chk('reviews_answered') = 'false|1 review(s) from the last 90 days have no reply.', 'PF11 unanswered reviews of the last 90 days are counted (older ones and answered ones are not)');

-- ---------------------------------------------------------------- photos
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_media_save(:'L1', jsonb_build_array(
  jsonb_build_object('id', 'm-cover', 'by_owner', true, 'format', 'PHOTO', 'category', 'COVER', 'thumb', 'https://lh3.googleusercontent.com/t1', 'url', 'https://lh3.googleusercontent.com/g1', 'description', 'Campus', 'created', now() - interval '10 days'),
  jsonb_build_object('id', 'm-logo', 'by_owner', true, 'format', 'PHOTO', 'category', 'PROFILE', 'thumb', 'javascript:alert(1)', 'url', 'http://insecure.example/x.jpg', 'created', now() - interval '400 days'),
  jsonb_build_object('id', 'm-class', 'by_owner', true, 'format', 'VIDEO', 'category', 'AT_WORK', 'thumb', 'https://lh3.googleusercontent.com/t3', 'created', NULL),
  jsonb_build_object('id', 'customers/c1', 'by_owner', false, 'format', 'PHOTO', 'category', 'CUSTOMER', 'thumb', 'https://lh3.googleusercontent.com/t4', 'created', now() - interval '2 days'),
  jsonb_build_object('id', '', 'by_owner', true), 'junk', NULL), 12, 30, true) = 4
  AND pg_temp.q('SELECT thumb_url IS NULL AND google_url IS NULL FROM public.gbp_media WHERE media_id = ''m-logo''') = 'true'
  AND pg_temp.q('SELECT media_owner || ''/'' || media_customer FROM public.gbp_location WHERE name = ''locations/111''') = '12/30',
  'PF12 photos are saved with Google''s totals; links that are not https are dropped, junk rows too');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.chk('photo_cover') = 'true|Set.' AND pg_temp.chk('photo_logo') = 'true|Set.' AND pg_temp.chk('photo_count') = 'true|You have 12; customers added 30.'
  AND pg_temp.chk('photo_fresh') LIKE 'true|Last added on %' AND pg_temp.chk('post_fresh') = 'false|No post on the profile.', 'PF13 once read, photos and posts are judged: cover, logo, how many, how recent');
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_media_save(:'L1', jsonb_build_array(jsonb_build_object('id', 'm-logo', 'by_owner', true, 'category', 'PROFILE', 'created', now() - interval '400 days')), 1, NULL, false) = 1
  AND pg_temp.q('SELECT count(*) FROM public.gbp_media WHERE location_id = ''a0000000-0000-4000-8000-000000000001''')::int = 4
  AND pg_temp.q('SELECT media_owner || ''/'' || media_customer FROM public.gbp_location WHERE name = ''locations/111''') = '1/30', 'PF14 a partial read never deletes photos; a missing total keeps the last one');
SELECT pg_temp.ok(public.svc_gbp_media_save(:'L1', jsonb_build_array(jsonb_build_object('id', 'm-logo', 'by_owner', true, 'category', 'PROFILE', 'created', now() - interval '400 days')), 1, 0, true) = 1
  AND pg_temp.q('SELECT count(*) FROM public.gbp_media WHERE location_id = ''a0000000-0000-4000-8000-000000000001''')::int = 1, 'PF15 a complete read removes the photos that are gone from Google');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.chk('photo_cover') LIKE 'false|No cover photo%' AND pg_temp.chk('photo_count') = 'false|You have 1; customers added 0.' AND pg_temp.chk('photo_fresh') LIKE 'false|Last added on %', 'PF16 no cover, too few and stale photos are each named');

-- ---------------------------------------------------------------- posts
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_posts_save(:'L1', jsonb_build_array(
  jsonb_build_object('id', 'p1', 'topic', 'STANDARD', 'state', 'LIVE', 'summary', 'New DGCA batch from 1 December.', 'cta_type', 'LEARN_MORE', 'cta_url', 'https://weoneaviation.in/dgca', 'media_url', 'https://lh3.googleusercontent.com/p1', 'search_url', 'https://local.google.com/place?id=1', 'created', now() - interval '3 days'),
  jsonb_build_object('id', 'p2', 'topic', 'EVENT', 'state', 'REJECTED', 'summary', '<b>Open day</b>', 'created', now() - interval '40 days'),
  jsonb_build_object('id', 'p3', 'topic', 'STANDARD', 'state', 'LIVE', 'summary', 'Old', 'created', now() - interval '100 days'),
  jsonb_build_object('id', ''), 'junk'), true) = 3, 'PF17 posts are saved with their state');
SELECT public.svc_gbp_posts_save(:'L2', jsonb_build_array(jsonb_build_object('id', 'u1', 'state', 'LIVE', 'summary', 'Other branch post', 'created', now())), true);
RESET ROLE;
SELECT pg_temp.ok(pg_temp.chk('post_fresh') LIKE 'true|Last post on %', 'PF18 a live post in the last 30 days passes the check');
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_posts_save(:'L1', jsonb_build_array(jsonb_build_object('id', 'p2', 'topic', 'EVENT', 'state', 'LIVE', 'summary', 'Open day', 'created', now() - interval '40 days')), false) = 1
  AND pg_temp.q('SELECT count(*) || state FROM public.gbp_post p WHERE location_id = ''a0000000-0000-4000-8000-000000000001'' AND post_id = ''p2'' GROUP BY state') = '1LIVE'
  AND pg_temp.q('SELECT count(*) FROM public.gbp_post WHERE location_id = ''a0000000-0000-4000-8000-000000000001''')::int = 3, 'PF19 a later read updates a post in place; a partial read deletes nothing');
SELECT pg_temp.ok(public.svc_gbp_posts_save(:'L1', jsonb_build_array(jsonb_build_object('id', 'p1', 'topic', 'STANDARD', 'state', 'LIVE', 'summary', 'New DGCA batch from 1 December.', 'cta_type', 'LEARN_MORE', 'cta_url', 'https://weoneaviation.in/dgca', 'created', now() - interval '3 days'),
  jsonb_build_object('id', 'p3', 'state', 'LIVE', 'summary', 'Old', 'created', now() - interval '100 days')), true) = 2
  AND pg_temp.q('SELECT count(*) FROM public.gbp_post WHERE location_id = ''a0000000-0000-4000-8000-000000000001''')::int = 2, 'PF20 a complete read removes posts deleted on Google');
RESET ROLE;
SET ROLE authenticated;
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((SELECT p @> '{"can_run": false}' AND jsonb_array_length(p->'profiles') = 1 AND p->'profiles'->0 @> '{"title": "We One Aviation", "can_post": true, "collected": true}'
  AND jsonb_array_length(p->'posts') = 2 AND p->'posts'->0 @> '{"post_id": "p1", "state": "LIVE", "cta_type": "LEARN_MORE", "profile": "We One Aviation"}' AND p->'waiting' = '[]' AND p::text NOT LIKE '%Other branch%'
  FROM (SELECT public.api_gbp_posts() p) z), 'PF21 the posts list: newest first, tracked profiles only');
SELECT pg_temp.ok((SELECT m @> '{"collected": true, "owner": 1, "customers": 0, "by_category": {"PROFILE": 1}}' AND jsonb_array_length(m->'items') = 1 AND m->'items'->0 @> '{"media_id": "m-logo", "by_owner": true}' AND m->>'last_added' IS NOT NULL
  FROM (SELECT public.api_gbp_media() m) z) AND jsonb_array_length(public.api_gbp_media(:'L2')->'items') = 0 AND public.api_gbp_media(:'L2') @> '{"collected": false, "owner": 0}'
  AND jsonb_array_length(public.api_gbp_posts(NULL, -5)->'posts') = 1 AND jsonb_array_length(public.api_gbp_profile(gen_random_uuid())) = 0, 'PF22 photos: totals, by kind, newest first; an untracked or unknown profile shows nothing; odd limits are harmless');

-- ---------------------------------------------------------------- publishing a post
SELECT pg_temp.as_('d');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hello')$q$, :'L2'), '%tracked profiles%', 'PF23 no post on a profile that is not tracked');
SELECT pg_temp.fails($q$SELECT public.api_gbp_post_create(gen_random_uuid(), 'Hello')$q$, '%tracked profiles%', 'PF23b or on one that does not exist');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, '   ')$q$, :'L1'), '%Write the post first%', 'PF24 an empty post is refused');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, repeat('a', 1501))$q$, :'L1'), '%under 1,500 characters (it has 1501)%', 'PF24b one of 1,501 characters too, with the count');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi <script>alert(1)</script>')$q$, :'L1'), '%No < or >%', 'PF24c HTML is refused');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', 'WIN_A_PRIZE', 'https://x.in')$q$, :'L1'), '%Unknown button type%', 'PF25 an unknown button is refused');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', 'BOOK', NULL)$q$, :'L1'), '%needs a link that starts with https%', 'PF25b a button without a link');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', 'BOOK', 'http://weoneaviation.in')$q$, :'L1'), '%needs a link that starts with https%', 'PF25c a link that is not https');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', 'BOOK', 'javascript:alert(1)')$q$, :'L1'), '%needs a link that starts with https%', 'PF25d a script as a link');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', NULL, 'https://weoneaviation.in')$q$, :'L1'), '%Choose what the button says%', 'PF25e a link without a button');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hi', NULL, NULL, 'http://x.in/a.jpg')$q$, :'L1'), '%photo must be a link that starts with https%', 'PF25f a photo link that is not https');
SELECT pg_temp.ok(public.api_gbp_post_create(:'L1', '  New CPL batch starts 1 December. Seats are limited to 20.  ', 'learn_more', ' https://weoneaviation.in/cpl ', 'https://weoneaviation.in/img/cpl.jpg') @> '{"status": "queued"}'
  AND pg_temp.q('SELECT summary || ''|'' || cta_type || ''|'' || cta_url || ''|'' || photo_url FROM public.gbp_post_out ORDER BY id DESC LIMIT 1') = 'New CPL batch starts 1 December. Seats are limited to 20.|LEARN_MORE|https://weoneaviation.in/cpl|https://weoneaviation.in/img/cpl.jpg',
  'PF26 an approver queues a post: trimmed, button type normalised');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'new cpl batch starts 1 december.   seats are limited to 20.')$q$, :'L1'), '%already published on this profile in the last 24 hours%', 'PF27 the same post twice in a day is refused (case and spacing ignored)');
SELECT pg_temp.ok(public.api_gbp_post_create(:'L1', 'Call us for the weekend batch.', 'CALL', 'https://ignored.example') @> '{"status": "queued"}'
  AND pg_temp.q('SELECT cta_type || ''|'' || (cta_url IS NULL) FROM public.gbp_post_out ORDER BY id DESC LIMIT 1') = 'CALL|true', 'PF28 a Call button carries no link (Google uses the profile''s number)');
SELECT pg_temp.ok((SELECT jsonb_array_length(p->'waiting') = 2 AND p->'waiting'->0 @> '{"status": "queued", "cta_type": "CALL"}' FROM (SELECT public.api_gbp_posts() p) z), 'PF29 queued posts are listed as waiting');
RESET ROLE;

-- ---------------------------------------------------------------- the send queue
SET ROLE service_role;
CREATE TEMP TABLE pq AS SELECT public.svc_gbp_post_queue() q;
GRANT ALL ON pq TO authenticated, service_role;
SELECT pg_temp.ok((SELECT jsonb_array_length(q) = 2 AND q->0 @> '{"account": "accounts/9", "location": "locations/111", "location_id": "a0000000-0000-4000-8000-000000000001", "connection_id": "c0000000-0000-4000-8000-000000000001", "cta_type": "LEARN_MORE"}'
  AND q->0->>'summary' LIKE 'New CPL batch%' FROM pq) AND public.svc_gbp_post_queue() = '[]', 'PF30 the sender takes each post once: a second run finds nothing to send');
SELECT public.svc_gbp_post_result((SELECT (q->0->>'id')::bigint FROM pq), 'sent', NULL, 'accounts/9/locations/111/localPosts/777');
SELECT public.svc_gbp_post_result((SELECT (q->0->>'id')::bigint FROM pq), 'failed', 'late answer');
SELECT pg_temp.ok(pg_temp.q(format('SELECT status || ''|'' || post_name || ''|'' || (sent_at IS NOT NULL) || ''|'' || (error IS NULL) FROM public.gbp_post_out WHERE id = %s', (SELECT q->0->>'id' FROM pq)))
  = 'sent|accounts/9/locations/111/localPosts/777|true|true', 'PF31 published: recorded with Google''s name for it; a late second answer changes nothing');
SELECT public.svc_gbp_post_result((SELECT (q->1->>'id')::bigint FROM pq), 'failed', repeat('Google rejected the post. ', 30));
SELECT pg_temp.ok(pg_temp.q(format('SELECT status || length(error) FROM public.gbp_post_out WHERE id = %s', (SELECT q->1->>'id' FROM pq))) = 'failed300', 'PF32 refused by Google: marked failed with the reason');
RESET ROLE;
SET ROLE authenticated;
SELECT pg_temp.as_('d');
SELECT public.api_gbp_post_create(:'L1', 'Call us for the weekend batch.', 'CALL');
SELECT pg_temp.ok((SELECT count(*) FROM jsonb_array_elements(public.api_gbp_posts()->'waiting') w WHERE w->>'status' = 'queued') = 1, 'PF33 a failed post does not block publishing the same text again');
RESET ROLE;
SET ROLE service_role;
SELECT public.svc_gbp_post_queue();
RESET ROLE;
SELECT pg_temp.x('UPDATE public.gbp_post_out SET taken_at = now() - interval ''10 minutes'' WHERE status = ''sending''');
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_gbp_post_queue() = '[]' AND pg_temp.q('SELECT status || ''|'' || error FROM public.gbp_post_out ORDER BY id DESC LIMIT 1') = 'failed|Google did not confirm this post. Check the profile on Google before publishing it again.',
  'PF34 a post whose outcome is unknown (the run died) is never sent again by itself; it is shown as failed with what to check');
RESET ROLE;
SET ROLE authenticated;
SELECT pg_temp.as_('c');
SELECT pg_temp.fails($q$SELECT public.api_gbp_post_cancel(1)$q$, '%Only Admin or approvers%', 'PF35 a viewer cannot remove a waiting post');
SELECT pg_temp.as_('d');
SELECT pg_temp.ok(public.api_gbp_post_cancel((SELECT (w->>'id')::bigint FROM jsonb_array_elements(public.api_gbp_posts()->'waiting') w LIMIT 1)) @> '{"status": "cancelled"}', 'PF36 a failed post can be removed from the list');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_cancel(%s)$q$, (SELECT q->0->>'id' FROM pq)), '%already on its way or was already removed%', 'PF36b a published post cannot');
SELECT pg_temp.fails($q$SELECT public.api_gbp_post_cancel(987654)$q$, '%already on its way or was already removed%', 'PF36c nor one that does not exist');
RESET ROLE;
SELECT pg_temp.x('INSERT INTO public.gbp_post_out (location_id, summary, status) SELECT ''a0000000-0000-4000-8000-000000000001'', ''Filler '' || g, ''sent'' FROM generate_series(1, 9) g');
SET ROLE authenticated;
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'One more today')$q$, :'L1'), '%At most 10 posts a day%', 'PF37 the 11th post of the day on one profile is refused');
RESET ROLE;
UPDATE public.gbp_location SET details = details || '{"can_post": false}' WHERE id = :'L1';
SELECT pg_temp.x('DELETE FROM public.gbp_post_out');
SET ROLE authenticated;
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_post_create(%L, 'Hello there')$q$, :'L1'), '%Google does not allow posts on this profile%', 'PF38 a profile Google does not allow posts on');
RESET ROLE;
SELECT pg_temp.ok(pg_temp.chk('post_fresh') IS NULL AND public.api_gbp_posts()->'profiles'->0 @> '{"can_post": false}', 'PF39 and its health check does not ask for posts');
UPDATE public.gbp_location SET tracked = true WHERE id = :'L2';
SELECT pg_temp.ok(jsonb_array_length(public.api_gbp_profile()) = 2 AND jsonb_array_length(public.api_gbp_profile(:'L2')) = 1 AND public.api_gbp_posts()::text LIKE '%Other branch post%', 'PF40 with two tracked profiles each has its own health check, and posts of both are listed');
SELECT pg_temp.ok((SELECT count(*) FROM pg_proc p WHERE p.proname IN ('gbp_health', 'api_gbp_profile', 'api_gbp_posts', 'api_gbp_media', 'api_gbp_post_create', 'api_gbp_post_cancel', 'svc_gbp_details_save', 'svc_gbp_posts_save', 'svc_gbp_media_save', 'svc_gbp_post_queue', 'svc_gbp_post_result')
    AND p.prosecdef AND p.proconfig::text LIKE '%search_path=%') = 11
  AND (SELECT bool_and(c.relrowsecurity) FROM pg_class c WHERE c.relname IN ('gbp_post', 'gbp_media', 'gbp_post_out'))
  AND NOT has_table_privilege('authenticated', 'public.gbp_post_out', 'SELECT') AND NOT has_function_privilege('authenticated', 'public.svc_gbp_post_result(bigint, text, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.api_gbp_post_create(uuid, text, text, text, text)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'crm_private.gbp_health(uuid)', 'EXECUTE'),
  'PF41 every function pins its search path, the tables are closed, privileges are as designed');
DO $$ BEGIN RAISE NOTICE 'ALL GBP PROFILE TESTS PASSED'; END $$;
