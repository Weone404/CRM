-- 139 CRM > Google > Google My Business: GB01-GB40. Each check prints PASS <name>; the first failure stops the run.
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
-- Test-only peeks behind the functions (run as the owner).
CREATE OR REPLACE FUNCTION pg_temp.q(p_sql text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE r text; BEGIN EXECUTE p_sql INTO r; RETURN r; END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b', 'Sales', 'Sales', '10000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c', 'Viewer', 'Sales', '10000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d', 'Approver', 'IT', '10000000-0000-0000-0000-00000000000d');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES
  ('00000000-0000-0000-0000-00000000000c', false), ('00000000-0000-0000-0000-00000000000d', true);
SELECT vault.create_secret('cid.apps.googleusercontent.com', 'ads_google_ads_client_id', 'x');
SELECT vault.create_secret('csecret', 'ads_google_ads_client_secret', 'x');
\set TOK1 '1//0gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-first_login'
\set TOK2 '1//0gBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB-second_login'
\set TOK3 '1//0gCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC-replaced'

-- ---------------------------------------------------------------- who may do what
SET ROLE anon;
SELECT pg_temp.fails($q$SELECT public.api_gbp_overview()$q$, '%permission denied%', 'GB01 signed-out visitors cannot call the screen');
SELECT pg_temp.fails($q$SELECT public.api_google_hub()$q$, '%permission denied%', 'GB01b signed-out visitors cannot call the hub');
SET ROLE authenticated;
SELECT pg_temp.as_('b');
SELECT pg_temp.fails($q$SELECT public.api_gbp_overview()$q$, '%not have access to Google My Business%', 'GB02 staff without ADS access cannot open Google My Business');
SELECT pg_temp.fails($q$SELECT public.api_google_hub()$q$, '%not have access to the Google section%', 'GB02b nor the Google hub');
SELECT pg_temp.fails($q$SELECT public.api_gbp_reviews()$q$, '%not have access%', 'GB02c nor the reviews');
SELECT pg_temp.as_('c');
SELECT pg_temp.ok((public.api_gbp_access()->>'can_view')::boolean AND NOT (public.api_gbp_access()->>'can_run')::boolean, 'GB03 ADS viewers can look, not change');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_add('We One', %L)$q$, :'TOK1'), '%Only Admin%', 'GB03b a viewer cannot add a Google login');
SELECT pg_temp.as_('d');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_add('We One', %L)$q$, :'TOK1'), '%Only Admin%', 'GB03c an approver cannot add a Google login either');
SELECT pg_temp.fails($q$SELECT public.svc_gbp_work()$q$, '%permission denied%', 'GB04 the function that returns tokens is closed to every signed-in user');
SELECT pg_temp.fails($q$SELECT public.svc_gbp_metrics_save(gen_random_uuid(), '[]')$q$, '%permission denied%', 'GB04b nobody in the browser can write numbers');
SELECT pg_temp.fails($q$SELECT count(*) FROM public.gbp_connection$q$, '%permission denied%', 'GB04c the tables cannot be read directly');
SELECT pg_temp.fails($q$SELECT crm_private.gbp_totals('{}', current_date, current_date)$q$, '%permission denied%', 'GB04d internal helpers are closed');

-- ---------------------------------------------------------------- Google logins
SELECT pg_temp.as_('a');
SELECT pg_temp.ok((public.api_gbp_overview()->'setup') @> '{"client": true, "connections": 0, "tracked": 0, "has_data": false}'
  AND public.api_gbp_overview()->'days' IS NOT NULL AND (public.api_gbp_overview()->'totals'->>'views')::int = 0, 'GB05 empty screen: setup list, zero totals, no error');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('x', '1//0gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')$q$, '%name of 2 to 60%', 'GB06 a one-letter name is refused');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('<script>alert(1)</script>', '1//0gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')$q$, '%name of 2 to 60%', 'GB06b HTML in a name is refused');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('We One', 'ya29.a0AfH6SMBxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')$q$, '%not a Google refresh token%', 'GB06c an access token pasted by mistake is refused');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('We One', '1//0g AAAA AAAA AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')$q$, '%not a Google refresh token%', 'GB06d a token with spaces is refused');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('We One', NULL)$q$, '%not a Google refresh token%', 'GB06e an empty token is refused');
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('We One', '1//' || repeat('A', 600))$q$, '%not a Google refresh token%', 'GB06f an absurdly long token is refused');
CREATE TEMP TABLE c AS SELECT 1 n, (public.api_gbp_connection_add('  We One Aviation ', :'TOK1')->>'id')::uuid id;
GRANT ALL ON c TO authenticated, service_role;
INSERT INTO c SELECT 2, (public.api_gbp_connection_add('Book My Charter', :'TOK2')->>'id')::uuid;
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_add('we one aviation', %L)$q$, :'TOK1'), '%already exists%', 'GB07 two logins cannot share a name (any letter case)');
SELECT pg_temp.ok(pg_temp.q('SELECT count(*) FROM vault.secrets WHERE name LIKE ''crm\_gbp\_refresh\_%''')::int = 2
  AND pg_temp.q(format('SELECT secret FROM vault.secrets WHERE name = crm_private.gbp_secret_name(%L)', (SELECT id FROM c WHERE n = 1))) = :'TOK1',
  'GB08 each login''s token is kept in Vault under its own name');
SELECT pg_temp.ok(public.api_gbp_overview()::text NOT LIKE '%1//%' AND public.api_google_hub()::text NOT LIKE '%1//%' AND public.api_gbp_overview()::text NOT LIKE '%csecret%',
  'GB09 no token or client secret ever comes back to the browser');
SELECT pg_temp.ok((SELECT jsonb_array_length(v->'connections') = 2 AND v->'connections'->0->>'label' = 'We One Aviation' AND v->'connections'->0->>'status' = 'new'
  AND (v->'connections'->0->>'locations')::int = 0 FROM (SELECT public.api_gbp_overview() v) z), 'GB10 logins are listed with a trimmed name and their state');
SELECT pg_temp.ok(pg_temp.q('SELECT count(*) FROM public.audit_log WHERE action = ''gbp_connection_added'' AND payload::text NOT LIKE ''%1//%''')::int = 2, 'GB10b adding a login is logged, without the token');

-- ---------------------------------------------------------------- what the collector saves
SET ROLE service_role;
SELECT pg_temp.ok((SELECT w->>'client_id' = 'cid.apps.googleusercontent.com' AND jsonb_array_length(w->'connections') = 2
  AND w->'connections'->0->>'refresh_token' = :'TOK1' AND w->'connections'->0->'locations' = '[]' FROM (SELECT public.svc_gbp_work() w) z),
  'GB11 the collector gets the Google client, every login and its token');
SELECT pg_temp.ok(jsonb_array_length(public.svc_gbp_work((SELECT id FROM c WHERE n = 2))->'connections') = 1, 'GB11b it can be limited to one login');
SELECT pg_temp.ok(public.svc_gbp_locations_save((SELECT id FROM c WHERE n = 1), '[
  {"account": "accounts/9", "name": "locations/111", "title": "We One Aviation", "address": "Dwarka, Delhi", "phone": "+91 98110 00000", "website": "https://weoneaviation.in/", "category": "Flight school", "maps_uri": "https://maps.google.com/?cid=1", "place_id": "ChIJ1", "verified": true}]') = 1
  AND pg_temp.q('SELECT tracked FROM public.gbp_location WHERE name = ''locations/111''') = 'true', 'GB12 a login with one profile: it is tracked at once');
SELECT pg_temp.ok(public.svc_gbp_locations_save((SELECT id FROM c WHERE n = 2), '[
  {"account": "accounts/7", "name": "locations/221", "title": "Book My Charter Delhi"}, {"account": "accounts/7", "name": "locations/222", "title": "Book My Charter Mumbai"},
  {"account": "accounts/7", "name": "locations/222/../x", "title": "bad"}, {"account": "x", "name": "locations/5"}, "junk", null, {"name": "locations/9"}]') = 2
  AND pg_temp.q('SELECT count(*) FROM public.gbp_location WHERE tracked')::int = 1, 'GB13 a login with several profiles: all listed, none tracked until chosen; malformed rows dropped');
SELECT pg_temp.ok(public.svc_gbp_locations_save((SELECT id FROM c WHERE n = 1), '[{"account": "accounts/9", "name": "locations/111", "title": "We One Aviation Academy", "verified": true},
  {"account": "accounts/9", "name": "locations/112", "title": "We One Noida"}]') = 2
  AND pg_temp.q('SELECT title || tracked FROM public.gbp_location WHERE name = ''locations/111''') = 'We One Aviation Academytrue'
  AND pg_temp.q('SELECT tracked FROM public.gbp_location WHERE name = ''locations/112''') = 'false', 'GB14 reading the profiles again refreshes details, keeps the choice, never tracks a newcomer by itself');
SELECT pg_temp.ok(public.svc_gbp_locations_save(gen_random_uuid(), '[{"account": "accounts/9", "name": "locations/1"}]') = 0 AND public.svc_gbp_locations_save((SELECT id FROM c WHERE n = 1), '{"a": 1}') = 0,
  'GB14b profiles for an unknown login, or a non-list, save nothing');
CREATE TEMP TABLE l AS SELECT name, id FROM (SELECT pg_temp.q('SELECT jsonb_object_agg(name, id) FROM public.gbp_location')::jsonb j) z, jsonb_each_text(j) e(name, id);
GRANT ALL ON l TO authenticated, service_role;
SELECT pg_temp.ok((SELECT (x->>'first')::boolean AND (x->>'reviews_stored')::int = 0 AND x->'keyword_months' = '[]' AND x->>'name' = 'locations/111'
  FROM (SELECT public.svc_gbp_work()->'connections'->0->'locations'->0 x) z), 'GB15 a profile never collected is marked for the long first read');
-- Daily numbers: 2026-11-10..11 current, one prior day; junk rows.
SELECT pg_temp.ok(public.svc_gbp_metrics_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '[
  {"d": "2026-11-11", "m": "BUSINESS_IMPRESSIONS_MOBILE_SEARCH", "v": 100}, {"d": "2026-11-11", "m": "BUSINESS_IMPRESSIONS_DESKTOP_SEARCH", "v": 40},
  {"d": "2026-11-11", "m": "BUSINESS_IMPRESSIONS_MOBILE_MAPS", "v": 50}, {"d": "2026-11-11", "m": "BUSINESS_IMPRESSIONS_DESKTOP_MAPS", "v": 10},
  {"d": "2026-11-11", "m": "CALL_CLICKS", "v": 6}, {"d": "2026-11-11", "m": "WEBSITE_CLICKS", "v": 9}, {"d": "2026-11-11", "m": "BUSINESS_DIRECTION_REQUESTS", "v": 4},
  {"d": "2026-11-11", "m": "MESSAGING_CLICKS", "v": 2}, {"d": "2026-11-11", "m": "BUSINESS_CONVERSATIONS", "v": 1}, {"d": "2026-11-11", "m": "BUSINESS_BOOKINGS", "v": 1},
  {"d": "2026-11-11", "m": "BUSINESS_FOOD_MENU_CLICKS", "v": 0},
  {"d": "2026-11-10", "m": "BUSINESS_IMPRESSIONS_MOBILE_SEARCH", "v": 60}, {"d": "2026-11-10", "m": "CALL_CLICKS", "v": 2},
  {"d": "2026-11-01", "m": "BUSINESS_IMPRESSIONS_MOBILE_SEARCH", "v": 30}, {"d": "2026-11-01", "m": "CALL_CLICKS", "v": 1},
  {"d": "11/11/2026", "m": "CALL_CLICKS", "v": 99}, {"d": "2026-11-11", "m": "call clicks; drop table", "v": 99}, {"d": "2026-11-11", "m": "CALL_CLICKS", "v": -4},
  {"d": "2026-11-11", "m": "WEBSITE_CLICKS", "v": "1e9"}, {"d": "2026-11-11", "m": "WEBSITE_CLICKS", "v": 1.5}, null, "x", {}]') = 15, 'GB16 daily numbers are saved; junk dates, names, negative and fractional values are dropped');
SELECT pg_temp.ok(public.svc_gbp_metrics_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '[{"d": "2026-11-10", "m": "CALL_CLICKS", "v": 3}]') = 1
  AND pg_temp.q('SELECT value FROM public.gbp_metric_daily WHERE day = ''2026-11-10'' AND metric = ''CALL_CLICKS''')::int = 3
  AND pg_temp.q('SELECT count(*) FROM public.gbp_metric_daily')::int = 15, 'GB17 a later read corrects a day instead of adding to it');
SELECT pg_temp.ok(public.svc_gbp_metrics_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '"nope"') = 0 AND public.svc_gbp_metrics_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '[]') = 0, 'GB17b nothing to save is not an error');
SELECT pg_temp.fails($q$SELECT public.svc_gbp_metrics_save(gen_random_uuid(), '[{"d": "2026-11-10", "m": "CALL_CLICKS", "v": 3}]')$q$, '%foreign key%', 'GB17c numbers for a profile that does not exist are refused');
-- A second, untracked profile with its own numbers (must not count until tracked).
SELECT public.svc_gbp_metrics_save((SELECT id::uuid FROM l WHERE name = 'locations/221'), '[{"d": "2026-11-11", "m": "CALL_CLICKS", "v": 50}, {"d": "2026-11-11", "m": "BUSINESS_IMPRESSIONS_MOBILE_MAPS", "v": 500}]');
-- Search words
SELECT pg_temp.ok(public.svc_gbp_keywords_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '2026-10-01', '[
  {"k": "Pilot Training Delhi", "v": 148}, {"k": "pilot training delhi ", "v": 100}, {"k": "dgca ground classes", "below": 15}, {"k": "", "v": 5}, {"k": "no number"}, {"k": "bad", "v": "x"}, 7]') = 2,
  'GB18 search words: same word in different case is one row, rare words keep "fewer than", empty rows dropped');
SELECT public.svc_gbp_keywords_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '2026-09-17', '[{"k": "pilot training delhi", "v": 90}, {"k": "old word", "v": 12}]');
SELECT pg_temp.ok(public.svc_gbp_keywords_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '2026-10-01', '[{"k": "pilot training delhi", "v": 150}, {"k": "dgca ground classes", "below": 15}, {"k": "cpl course", "v": 20}]') = 3
  AND pg_temp.q('SELECT count(*) FROM public.gbp_keyword_monthly WHERE month = ''2026-10-01''')::int = 3
  AND pg_temp.q('SELECT count(*) FROM public.gbp_keyword_monthly WHERE month = ''2026-09-01''')::int = 2, 'GB19 reading a month again replaces that month only; any day of a month means that month');
-- Reviews
SELECT pg_temp.ok(public.svc_gbp_reviews_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '[
  {"id": "r1", "reviewer": "Asha V", "stars": 5, "comment": "Great faculty", "created": "2026-11-10T10:00:00Z", "updated": "2026-11-10T10:00:00Z", "reply": "Thank you, Asha.", "reply_at": "2026-11-11T05:00:00Z"},
  {"id": "r2", "reviewer": "A Google user", "stars": 2, "comment": "", "created": "2026-11-05T10:00:00Z", "updated": null, "reply": "", "reply_at": null},
  {"id": "r3", "reviewer": "Ravi", "stars": 4, "comment": "Good", "created": "2026-10-01T10:00:00Z"},
  {"id": "r4", "reviewer": "No rating", "stars": null, "created": "2026-09-01T10:00:00Z"}, {"id": "r5", "stars": 9}, {"id": "", "stars": 5}, {"stars": 5}, "x"]', 213, 4.66) = 5
  AND pg_temp.q('SELECT rating || ''/'' || reviews_total FROM public.gbp_location WHERE name = ''locations/111''') = '4.66/213'
  AND pg_temp.q('SELECT stars IS NULL FROM public.gbp_review WHERE review_id = ''r5''') = 'true'
  AND pg_temp.q('SELECT reply IS NULL FROM public.gbp_review WHERE review_id = ''r2''') = 'true', 'GB20 reviews are saved with Google''s own total and rating; an impossible rating is left empty; an empty reply is "no reply"');
SELECT pg_temp.ok(public.svc_gbp_reviews_save((SELECT id::uuid FROM l WHERE name = 'locations/111'), '[{"id": "r2", "reviewer": "A Google user", "stars": 3, "comment": "Edited", "created": "2026-11-05T10:00:00Z", "reply": "Sorry to hear that."}]', NULL, 99) = 1
  AND pg_temp.q('SELECT stars || comment || reply FROM public.gbp_review WHERE review_id = ''r2''') = '3EditedSorry to hear that.'
  AND pg_temp.q('SELECT count(*) FROM public.gbp_review')::int = 5
  AND pg_temp.q('SELECT rating || ''/'' || reviews_total FROM public.gbp_location WHERE name = ''locations/111''') = '4.66/213', 'GB21 an edited review replaces the old one; a missing total or impossible rating keeps the last good one');
SELECT public.svc_gbp_reviews_save((SELECT id::uuid FROM l WHERE name = 'locations/221'), '[{"id": "x1", "reviewer": "Other", "stars": 1, "comment": "Bad", "created": "2026-11-09T10:00:00Z"}]', 87, 3.5);
SELECT pg_temp.ok((SELECT NOT (x->>'first')::boolean AND (x->>'reviews_stored')::int = 5 AND x->'keyword_months' = '["2026-09-01", "2026-10-01"]'
  FROM (SELECT public.svc_gbp_work()->'connections'->0->'locations'->0 x) z), 'GB22 after the first read the collector is told what is already stored');
SELECT public.svc_gbp_connection_status((SELECT id FROM c WHERE n = 1), 'connected', 'ignored', 'owner@weoneaviation.in');
SELECT public.svc_gbp_connection_status((SELECT id FROM c WHERE n = 2), 'waiting_google', repeat('Google has not approved this project yet. ', 40), NULL);
SELECT pg_temp.fails(format($q$SELECT public.svc_gbp_connection_status(%L, 'hacked', NULL, NULL)$q$, (SELECT id FROM c WHERE n = 1)), '%check constraint%', 'GB23 an unknown state is refused');
SELECT public.svc_gbp_run_end(public.svc_gbp_run_begin('sync'), 'ok', '1 profile(s), 15 daily numbers');
SELECT public.svc_gbp_run_end(public.svc_gbp_run_begin('discover'), 'error', repeat('x', 3000));
RESET ROLE;

-- ---------------------------------------------------------------- the screen
SET ROLE authenticated;
SELECT pg_temp.as_('c');
CREATE TEMP TABLE o AS SELECT public.api_gbp_overview() v;
GRANT ALL ON o TO authenticated;
SELECT pg_temp.ok((SELECT v->'connections'->0->>'status' = 'connected' AND v->'connections'->0->>'error' IS NULL AND v->'connections'->0->>'email' = 'owner@weoneaviation.in'
  AND v->'connections'->1->>'status' = 'waiting_google' AND length(v->'connections'->1->>'error') = 500 AND (v->'setup'->>'waiting_google')::boolean
  AND (v->'setup'->>'connected')::int = 1 AND (v->'setup'->>'locations')::int = 4 AND (v->'setup'->>'tracked')::int = 1 AND (v->'setup'->>'has_data')::boolean FROM o),
  'GB24 each login shows its own state ("Waiting for Google" is not an error of the others); long messages are cut');
SELECT pg_temp.ok((SELECT v->'period' @> '{"days": 28, "from": "2026-10-15", "to": "2026-11-11", "prev_from": "2026-09-17", "prev_to": "2026-10-14", "last_day": "2026-11-11"}' FROM o),
  'GB25 the period ends on the last day Google has reported, with an equal period before it');
SELECT pg_temp.ok((SELECT v->'totals' @> '{"views": 290, "search": 230, "maps": 60, "mobile": 240, "desktop": 50, "search_mobile": 190, "search_desktop": 40, "maps_mobile": 50, "maps_desktop": 10,
    "calls": 10, "website": 9, "directions": 4, "messages": 3, "bookings": 1, "actions": 27, "days": 3}' FROM o),
  'GB26 totals: views = Search + Maps = phone + computer; actions = calls + website + directions + messages + bookings; untracked profiles do not count');
SELECT pg_temp.ok((SELECT (v->'prev'->>'views')::int = 0 AND (v->'prev'->>'actions')::int = 0 AND jsonb_array_length(v->'days') = 28 AND jsonb_array_length(v->'prev_days') = 28
  AND v->'days'->27 @> '{"d": "2026-11-11", "views": 200, "search": 140, "maps": 60, "calls": 6, "website": 9, "directions": 4, "messages": 3, "actions": 23}'
  AND v->'days'->25 @> '{"d": "2026-11-09", "views": 0, "actions": 0}' FROM o), 'GB27 one row per day with no gaps; a day without data is 0');
SELECT pg_temp.ok((SELECT (SELECT sum((d->>'views')::int) FROM jsonb_array_elements(v->'days') d) = (v->'totals'->>'views')::int
  AND (SELECT sum((d->>'actions')::int) FROM jsonb_array_elements(v->'days') d) = (v->'totals'->>'actions')::int
  AND (SELECT sum((w->>'views')::int) FROM jsonb_array_elements(v->'weekdays') w) = (v->'totals'->>'views')::int FROM o), 'GB28 the chart, the weekday bars and the totals add up to the same numbers');
SELECT pg_temp.ok((SELECT v->'keywords' @> '{"month": "2026-10-01", "prev_month": "2026-09-01", "count": 3}' AND v->'keywords'->'rows'->0 @> '{"k": "pilot training delhi", "v": 150, "pv": 90}'
  AND v->'keywords'->'rows'->1 @> '{"k": "cpl course", "v": 20, "pv": null}' AND v->'keywords'->'rows'->2 @> '{"k": "dgca ground classes", "v": null, "below": 15}' FROM o),
  'GB29 search words of the latest month, biggest first, with last month beside them; rare words last');
SELECT pg_temp.ok((SELECT v->'reviews' @> '{"total": 213, "rating": 4.66, "stored": 5, "unreplied": 3, "new": 2, "new_prev": 1, "by_star": {"1": 0, "2": 0, "3": 1, "4": 1, "5": 1}}'
  AND v->'reviews'->'latest'->0->>'review_id' = 'r1' AND jsonb_array_length(v->'reviews'->'latest') = 5 FROM o), 'GB30 reviews: Google''s total and rating, stars, waiting for a reply, new this period');
SELECT pg_temp.ok((SELECT v->'runs'->'sync'->>'status' = 'ok' AND length(v->'runs'->'discover'->>'detail') = 1000 FROM o), 'GB31 the last run of each job is shown');
SELECT pg_temp.ok((public.api_gbp_overview(NULL, 7)->'period'->>'from') = '2026-11-05' AND (public.api_gbp_overview(NULL, 7)->'totals'->>'views')::int = 260
  AND (public.api_gbp_overview(NULL, 7)->'prev'->>'views')::int = 30, 'GB32 7 days: the earlier day moves into "the period before"');
SELECT pg_temp.ok((public.api_gbp_overview(NULL, -5)->'period'->>'days')::int = 7 AND (public.api_gbp_overview(NULL, 99999)->'period'->>'days')::int = 180
  AND (public.api_gbp_overview(NULL, NULL)->'period'->>'days')::int = 28 AND jsonb_array_length(public.api_gbp_overview(NULL, 99999)->'days') = 180, 'GB33 absurd periods are pulled into 7-180 days');
SELECT pg_temp.ok(public.api_gbp_overview(gen_random_uuid())->'selected' = 'null' AND (public.api_gbp_overview((SELECT id::uuid FROM l WHERE name = 'locations/221'))->'totals'->>'calls')::int = 10,
  'GB34 an unknown or untracked profile id shows all tracked profiles, never someone else''s numbers');
SELECT pg_temp.ok(jsonb_array_length(public.api_gbp_reviews()) = 5 AND jsonb_array_length(public.api_gbp_reviews(NULL, 'unreplied')) = 3 AND jsonb_array_length(public.api_gbp_reviews(NULL, 'low')) = 1
  AND jsonb_array_length(public.api_gbp_reviews(NULL, 'all', 2)) = 2 AND jsonb_array_length(public.api_gbp_reviews(NULL, $q$'; DROP TABLE gbp_review; --$q$, -3)) = 1
  AND public.api_gbp_reviews(NULL, 'low')->0->>'review_id' = 'r2', 'GB35 reviews list: all, waiting for a reply, 1-3 stars; odd filters and limits are harmless');

-- ---------------------------------------------------------------- choosing profiles
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_location_track(%L, true)$q$, (SELECT id FROM l WHERE name = 'locations/221')), '%Only Admin or approvers%', 'GB36 a viewer cannot choose profiles');
SELECT pg_temp.as_('d');
SELECT pg_temp.fails($q$SELECT public.api_gbp_location_track(gen_random_uuid(), true)$q$, '%no longer exists%', 'GB36b a profile that is gone gives a clear message');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_location_track(%L, NULL)$q$, (SELECT id FROM l WHERE name = 'locations/221')), '%on or off%', 'GB36c neither on nor off is refused');
SELECT pg_temp.ok((public.api_gbp_location_track((SELECT id::uuid FROM l WHERE name = 'locations/221'), true)->>'tracked')::boolean
  AND (public.api_gbp_location_track((SELECT id::uuid FROM l WHERE name = 'locations/221'), true)->>'tracked')::boolean, 'GB37 an approver can track a second profile (twice is the same as once)');
CREATE TEMP TABLE o2 AS SELECT public.api_gbp_overview() v, public.api_gbp_overview((SELECT id::uuid FROM l WHERE name = 'locations/221')) one, public.api_google_hub() hub;
GRANT ALL ON o2 TO authenticated;
SELECT pg_temp.ok((SELECT (v->'totals'->>'views')::int = 790 AND (v->'totals'->>'calls')::int = 60 AND (v->'reviews'->>'total')::int = 300 AND (v->'reviews'->>'rating')::numeric = 4.32
  AND (v->'reviews'->>'stored')::int = 6 AND (v->'reviews'->'by_star'->>'1')::int = 1 FROM o2), 'GB38 all profiles together: numbers add up; the rating is weighted by each profile''s review count');
SELECT pg_temp.ok((SELECT one->>'selected' = (SELECT id FROM l WHERE name = 'locations/221') AND (one->'totals'->>'views')::int = 500 AND (one->'totals'->>'calls')::int = 50
  AND (one->'reviews'->>'total')::int = 87 AND one->'keywords'->'rows' = '[]' AND one->'keywords'->'month' = 'null' FROM o2), 'GB39 one profile on its own shows only its numbers, reviews and words');
SELECT pg_temp.ok(jsonb_array_length(public.api_gbp_reviews((SELECT id::uuid FROM l WHERE name = 'locations/221'))) = 1 AND jsonb_array_length(public.api_gbp_reviews(NULL, 'low')) = 2, 'GB39b reviews follow the chosen profile');
SELECT pg_temp.ok((SELECT hub->'gbp' @> '{"connections": 2, "tracked": 2, "waiting_google": true, "last_day": "2026-11-11", "rating": 4.32, "reviews": 300}'
  AND (hub->'gbp'->'totals'->>'views')::int = 790 AND (hub->'gbp'->'prev'->>'views')::int = 0 AND hub ? 'website' AND hub ? 'ads' AND (hub->'ads'->>'spend')::numeric = 0 FROM o2),
  'GB40 the Google hub cards: Business Profile summary beside Website and Ads');
SELECT public.api_gbp_location_track((SELECT id::uuid FROM l WHERE name = 'locations/221'), false);
SELECT pg_temp.ok((public.api_gbp_overview()->'totals'->>'views')::int = 290 AND pg_temp.q('SELECT count(*) FROM public.gbp_metric_daily')::int = 17, 'GB41 stopping a profile removes it from the totals but keeps what was collected');

-- ---------------------------------------------------------------- replacing and removing a login
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_token(%L, %L)$q$, (SELECT id FROM c WHERE n = 2), :'TOK3'), '%Only Admin%', 'GB42 an approver cannot replace a token');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_remove(%L)$q$, (SELECT id FROM c WHERE n = 2)), '%Only Admin%', 'GB42b nor remove a login');
SELECT pg_temp.as_('a');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_token(%L, 'nope')$q$, (SELECT id FROM c WHERE n = 2)), '%not a Google refresh token%', 'GB43 a bad replacement token is refused and the old one stays');
SELECT pg_temp.fails(format($q$SELECT public.api_gbp_connection_token(gen_random_uuid(), %L)$q$, :'TOK3'), '%no longer exists%', 'GB43b replacing the token of a removed login gives a clear message');
SELECT public.api_gbp_connection_token((SELECT id FROM c WHERE n = 2), :'TOK3');
SELECT pg_temp.ok(pg_temp.q(format('SELECT secret FROM vault.secrets WHERE name = crm_private.gbp_secret_name(%L)', (SELECT id FROM c WHERE n = 2))) = :'TOK3'
  AND pg_temp.q('SELECT count(*) FROM vault.secrets WHERE name LIKE ''crm\_gbp\_refresh\_%''')::int = 2
  AND public.api_gbp_overview()->'connections'->1->>'status' = 'new' AND public.api_gbp_overview()->'connections'->1->>'error' IS NULL, 'GB44 a new token replaces the old one and clears "sign in again"');
SELECT pg_temp.ok((public.api_gbp_connection_remove((SELECT id FROM c WHERE n = 2))->>'removed')::boolean, 'GB45a a login can be removed');
SELECT pg_temp.ok((public.api_gbp_connection_remove((SELECT id FROM c WHERE n = 2))->>'removed')::boolean IS FALSE
  AND pg_temp.q('SELECT count(*) FROM vault.secrets WHERE name LIKE ''crm\_gbp\_refresh\_%''')::int = 1 AND pg_temp.q('SELECT count(*) FROM public.gbp_location')::int = 2
  AND pg_temp.q('SELECT count(*) FROM public.gbp_metric_daily')::int = 15 AND pg_temp.q('SELECT count(*) FROM public.gbp_review')::int = 5
  AND pg_temp.q('SELECT count(*) FROM vault.secrets WHERE name LIKE ''ads_google_ads_client%''')::int = 2,
  'GB45 removing a login deletes its token, profiles and their numbers; the other login and the Google client stay; removing twice is harmless');
DO $$ BEGIN FOR i IN 1..19 LOOP PERFORM public.api_gbp_connection_add('Login ' || i, '1//0gDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD' || i); END LOOP; END $$;
SELECT pg_temp.fails($q$SELECT public.api_gbp_connection_add('One too many', '1//0gEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE')$q$, '%At most 20%', 'GB46 the 21st Google login is refused');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname LIKE '%gbp%' AND p.prosecdef
    AND NOT coalesce(p.proconfig::text LIKE '%search_path=%', false)) = 0
  AND (SELECT bool_and(c.relrowsecurity) FROM pg_class c WHERE c.relname LIKE 'gbp\_%' AND c.relkind = 'r'), 'GB47 every function pins its search path and every table has row security on');
SELECT pg_temp.ok(NOT has_function_privilege('anon', 'public.api_gbp_overview(uuid, int)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.svc_gbp_work(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.svc_gbp_reviews_save(uuid, jsonb, int, numeric)', 'EXECUTE') AND has_function_privilege('service_role', 'public.svc_gbp_work(uuid)', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'public.gbp_review', 'SELECT') AND NOT has_table_privilege('anon', 'public.gbp_connection', 'SELECT'), 'GB48 privileges are exactly as designed');
DO $$ BEGIN RAISE NOTICE 'ALL GBP TESTS PASSED'; END $$;
