-- 145 time-of-day bids. ST01-ST08. Runs after 10_premium_tests.sql in the same database (144 re-applied, 145 applied twice).
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
CREATE OR REPLACE FUNCTION pg_temp.gate(p_kind text, p_payload jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT crm_private.ads_google_gate('a1440000-0000-4000-8000-000000000001', p_kind, p_payload) $$;
CREATE OR REPLACE FUNCTION pg_temp.blocks(p_kind text, p_payload jsonb, p_like text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pg_temp.gate(p_kind, p_payload)->'blockers') m WHERE m ILIKE p_like) $$;
CREATE OR REPLACE FUNCTION pg_temp.clean(p_kind text, p_payload jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_array_length(pg_temp.gate(p_kind, p_payload)->'blockers') = 0 $$;
CREATE OR REPLACE FUNCTION pg_temp.sch(p_slots jsonb, p_more jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('campaign_id', '24283129095', 'slots', p_slots) || p_more $$;
SET client_min_messages = notice;
UPDATE public.ads_config SET value = 'on' WHERE key = 'google_targeting_locked';

SELECT pg_temp.ok(pg_temp.clean('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":6,"bid_pct":-30},{"start_hour":6,"end_hour":24}]'))
  AND pg_temp.clean('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24,"bid_pct":0}]'))
  AND pg_temp.clean('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":6,"bid_pct":-90},{"start_hour":6,"end_hour":10},{"start_hour":10,"end_hour":14},{"start_hour":14,"end_hour":18,"bid_pct":900},{"start_hour":18,"end_hour":22},{"start_hour":22,"end_hour":24}]')),
  'ST01 a day split into 1-6 slots that cover all 24 hours passes (bids from -90% to +900%)');
SELECT pg_temp.ok(pg_temp.clean('campaign_geo', '{"campaign_id":"24283129095","add":["1007801"]}')
  AND pg_temp.clean('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50"]}')
  AND pg_temp.blocks('campaign_create', '{}', 'Campaign name must be%') AND pg_temp.blocks('made_up', '{}', 'Unknown operation type.'),
  'ST02 every older kind still gets its own checks through both layers');
SELECT pg_temp.ok(pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":6},{"start_hour":7,"end_hour":24}]'), '%hour 6 is not covered%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":8},{"start_hour":6,"end_hour":24}]'), '%hour 8 is covered twice%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":6,"end_hour":24}]'), '%hour 0 is not covered%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":22}]'), 'The slots stop at 22:00%the ads go off%'),
  'ST03 a gap, an overlap or a short day is blocked: the ads can never go off by accident');
SELECT pg_temp.ok(pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":25}]'), 'Every slot needs whole hours%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":"6.5"},{"start_hour":"6.5","end_hour":24}]'), 'Every slot needs whole hours%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":5,"end_hour":5}]'), 'Every slot needs whole hours%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('["night"]'), 'Every slot needs whole hours%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24,"bid_pct":-91}]'), 'bid_pct must be%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24,"bid_pct":901}]'), 'bid_pct must be%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24,"bid_pct":12.5}]'), 'bid_pct must be%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[]'), 'Give 1-6 time slots%')
  AND pg_temp.blocks('ad_schedule', '{"campaign_id":"24283129095"}', 'Give 1-6 time slots%')
  AND pg_temp.blocks('ad_schedule', jsonb_build_object('campaign_id', '1', 'slots', (SELECT jsonb_agg(jsonb_build_object('start_hour', h, 'end_hour', h + 1)) FROM generate_series(0, 23) h)), 'Give 1-6 time slots%')
  AND pg_temp.blocks('ad_schedule', '{"slots":[{"start_hour":0,"end_hour":24}]}', 'campaign_id is required.'),
  'ST04 whole hours only, bids within -90% to +900%, 1-6 slots, and a campaign');
SELECT pg_temp.ok(pg_temp.clean('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24}]', '{"remove":["customers/6318538100/campaignCriteria/24283129095~300001"]}'))
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24}]', '{"remove":["customers/6318538100/campaignCriteria/555~300001"]}'), 'remove takes this campaign%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24}]', '{"remove":["customers/1111111111/campaignCriteria/24283129095~300001"]}'), 'remove takes this campaign%')
  AND pg_temp.blocks('ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24}]', '{"remove":"all"}'), 'remove takes this campaign%'),
  'ST05 an old schedule can be replaced only with this campaign''s own rows');
INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type) VALUES
  ('a1440000-0000-4000-8000-000000000001', 'ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":24,"bid_pct":-10}]'), 'agent'),
  ('a1440000-0000-4000-8000-000000000001', 'ad_schedule', pg_temp.sch('[{"start_hour":0,"end_hour":6,"bid_pct":-30},{"start_hour":6,"end_hour":24}]'), 'user');
SELECT pg_temp.ok((SELECT bool_and(status = 'pending') AND count(*) = 2 FROM public.ads_google_ops WHERE kind = 'ad_schedule'),
  'ST06 an agent''s schedule waits for the owner even on Automatic');
UPDATE public.ads_google_ops SET status = 'approved', approved_by = '00000000-0000-0000-0000-00000000000a', approved_at = now() WHERE kind = 'ad_schedule' AND created_by_type = 'user';
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(v->>'kind' = 'ad_schedule') FROM jsonb_array_elements(public.svc_ads_google_build_work()) v)
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.svc_ads_google_op_work()) v WHERE v->>'kind' = 'ad_schedule')
  AND (SELECT public.svc_ads_google_build_peek(id)->>'kind' = 'ad_schedule' FROM public.ads_google_ops WHERE kind = 'ad_schedule' AND status = 'approved'),
  'ST07 schedules are run (and dry-run) by ads-google-ops only');
SELECT pg_temp.ok((SELECT (length(value) - length(replace(value, 'Verified research (25 Nov 2026', ''))) / length('Verified research (25 Nov 2026') = 1
     AND value LIKE '%Owner decisions (25 Nov 2026%Verified research (25 Nov 2026%' AND value LIKE '%never copy the claims%' FROM public.ads_config WHERE key = 'google_brand_facts'),
  'ST08 the verified research is added to the AI team''s facts once (145 ran twice), after the owner''s decisions');
\echo ALL SCHEDULE TESTS PASSED
