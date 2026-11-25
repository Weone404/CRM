-- 144 ADS premium targeting. PT01-PT24. Each check prints PASS <name>; the first failure stops the run.
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Admin', 'Admin', '10000000-0000-0000-0000-00000000000a');
INSERT INTO public.ads_clients (id, name) VALUES ('c1440000-0000-4000-8000-000000000001', 'We One Aviation');
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status, last_ok_at) VALUES
  ('a1440000-0000-4000-8000-000000000001', 'c1440000-0000-4000-8000-000000000001', 'google', '6318538100', 'We One', 'INR', 'Asia/Kolkata', 'connected', now());
INSERT INTO public.ads_campaigns (account_id, external_id, name, status, daily_budget) VALUES
  ('a1440000-0000-4000-8000-000000000001', '24283129095', 'We-Aviation-Search-sep-2026', 'ENABLED', 140),
  ('a1440000-0000-4000-8000-000000000001', '111', 'Old campaign', 'PAUSED', 700);
INSERT INTO public.ads_config (key, value) VALUES ('google_cap_daily', '200'), ('google_cap_monthly', '6080'), ('autopilot_google', 'auto')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
CREATE OR REPLACE FUNCTION pg_temp.gate(p_kind text, p_payload jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT crm_private.ads_google_gate('a1440000-0000-4000-8000-000000000001', p_kind, p_payload) $$;
CREATE OR REPLACE FUNCTION pg_temp.blocks(p_kind text, p_payload jsonb, p_like text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pg_temp.gate(p_kind, p_payload)->'blockers') m WHERE m ILIKE p_like) $$;
CREATE OR REPLACE FUNCTION pg_temp.clean(p_kind text, p_payload jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_array_length(pg_temp.gate(p_kind, p_payload)->'blockers') = 0 $$;
CREATE OR REPLACE FUNCTION pg_temp.gop(p_kind text, p_payload jsonb, p_type text DEFAULT 'user', p_status text DEFAULT 'pending') RETURNS public.ads_google_ops
LANGUAGE sql AS $$
  INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type, status)
  VALUES ('a1440000-0000-4000-8000-000000000001', p_kind, p_payload, p_type, p_status) RETURNING * $$;
-- a good new campaign (60 a day next to the running 140 = the 200 limit) and a good income filter
CREATE OR REPLACE FUNCTION pg_temp.camp(p_change jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"name":"WOA Search - Other cities","daily_budget":60,"max_cpc":20,"locations":["9061645","1007801"]}'::jsonb || p_change $$;
SET client_min_messages = notice;

-- the old gate still answers for everything it knew
SELECT pg_temp.ok(pg_temp.clean('campaign_geo', '{"campaign_id":"24283129095","add":["1007801"]}')
  AND pg_temp.blocks('campaign_geo', '{"campaign_id":"24283129095"}', 'Nothing to change.')
  AND pg_temp.blocks('made_up', '{}', 'Unknown operation type.'), 'PT01 old kinds pass through unchanged; an unknown kind is still unknown');

-- campaign_create
SELECT pg_temp.ok(pg_temp.clean('campaign_create', pg_temp.camp()) AND pg_temp.clean('campaign_create', pg_temp.camp('{"status":"paused"}')),
  'PT02 a new campaign that fits the daily limit passes (running 140 + new 60 = limit 200)');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"daily_budget":60.01}'), '%up to 200.01 a day, above the daily limit of 200%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"daily_budget":60.01,"status":"PAUSED"}'), '%above the daily limit%'),
  'PT03 one paisa over the daily limit is blocked, paused or not');
UPDATE public.ads_config SET value = '' WHERE key = 'google_cap_daily';
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp(), 'Set a daily spend limit first%'), 'PT04 no daily limit: no new campaign');
UPDATE public.ads_config SET value = '200' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '50' WHERE key = 'google_cap_monthly';
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp(), '%above the monthly limit of 50%'), 'PT05 the monthly limit also blocks it');
UPDATE public.ads_config SET value = '6080' WHERE key = 'google_cap_monthly';
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"daily_budget":0}'), 'daily_budget must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"daily_budget":"abc"}'), 'daily_budget must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"daily_budget":10.123}'), 'daily_budget must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp() - 'daily_budget', 'daily_budget must be%'), 'PT06 budget must be a real amount (not 0, text, 3 decimals or missing)');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp() - 'locations', 'Give at least one location%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"locations":[]}'), 'Give at least one location%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"locations":"1007801"}'), 'Give at least one location%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"locations":["1007801","delhi"]}'), 'Location ids must be numeric%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"locations":["1007801",{"id":1}]}'), 'Location ids must be numeric%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"locations":["1007801","1007801"]}'), 'A location is listed twice.')
  AND pg_temp.blocks('campaign_create', pg_temp.camp(jsonb_build_object('locations', (SELECT jsonb_agg(g::text) FROM generate_series(1, 26) g))), 'At most 25 locations%')
  AND pg_temp.clean('campaign_create', pg_temp.camp(jsonb_build_object('locations', (SELECT jsonb_agg(g::text) FROM generate_series(1, 25) g)))),
  'PT07 locations: at least one (worldwide is never possible), numeric, no repeats, at most 25');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"name":"ab"}'), 'Campaign name must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp() - 'name', 'Campaign name must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"name":"we-aviation-SEARCH-sep-2026"}'), 'A campaign named%already exists.')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"name":" Old campaign "}'), 'A campaign named%already exists.'), 'PT08 name required and not one already used (any case, paused included)');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"max_cpc":2.99}'), 'max_cpc must be between 3 and 150%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"max_cpc":150.01}'), 'max_cpc must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp('{"max_cpc":"x"}'), 'max_cpc must be%')
  AND pg_temp.blocks('campaign_create', pg_temp.camp() - 'max_cpc', 'max_cpc must be%')
  AND pg_temp.clean('campaign_create', pg_temp.camp('{"max_cpc":3}')), 'PT09 click limit inside the same floor and ceiling as the rest of ADS');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"status":"REMOVED"}'), 'status must be ENABLED or PAUSED.'), 'PT10 status can only be ENABLED or PAUSED');
UPDATE public.ads_accounts SET status = 'auth_required' WHERE id = 'a1440000-0000-4000-8000-000000000001';
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp(), '%not connected%') AND pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50"]}', '%not connected%')
  AND NOT pg_temp.blocks('campaign_create', pg_temp.camp(), 'Unknown operation type.'), 'PT11 the shared checks still apply to the new kinds (account not connected)');
UPDATE public.ads_accounts SET status = 'connected' WHERE id = 'a1440000-0000-4000-8000-000000000001';

-- income_filter
SELECT pg_temp.ok(pg_temp.clean('income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_0_50","INCOME_RANGE_50_60","INCOME_RANGE_60_70","INCOME_RANGE_70_80"]}')
  AND pg_temp.clean('income_filter', '{"ad_group_id":"5","exclude":["income_range_0_50"]}')
  AND jsonb_array_length(pg_temp.gate('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50"]}')->'warnings') = 0,
  'PT12 shutting income groups out of a campaign or an ad group passes');
SELECT pg_temp.ok(pg_temp.clean('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_UNDETERMINED"]}')
  AND (pg_temp.gate('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_UNDETERMINED"]}')->'warnings'->>0) LIKE 'Google does not know the income of many people%',
  'PT13 shutting out "unknown" is allowed but warned about (it can cut reach sharply)');
SELECT pg_temp.ok(pg_temp.blocks('income_filter', '{"exclude":["INCOME_RANGE_0_50"]}', 'Give campaign_id or ad_group_id%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","ad_group_id":"2","exclude":["INCOME_RANGE_0_50"]}', 'Give campaign_id or ad_group_id%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"abc","exclude":["INCOME_RANGE_0_50"]}', 'Give campaign_id or ad_group_id%'), 'PT14 exactly one of campaign or ad group');
SELECT pg_temp.ok(pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":["RICH"]}', 'Income groups are:%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":[5]}', 'Income groups are:%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":"INCOME_RANGE_0_50"}', 'exclude and remove must be lists.')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50","income_range_0_50"]}', 'An income group is listed twice.')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1"}', 'Nothing to change.')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":[]}', 'Nothing to change.'), 'PT15 only Google''s seven groups, each once, and something to change');
SELECT pg_temp.ok(pg_temp.blocks('income_filter', '{"campaign_id":"1","exclude":["INCOME_RANGE_0_50","INCOME_RANGE_50_60","INCOME_RANGE_60_70","INCOME_RANGE_70_80","INCOME_RANGE_80_90","INCOME_RANGE_90_UP","INCOME_RANGE_UNDETERMINED"]}',
  'At least one income group must stay%'), 'PT16 all seven groups can never be shut out together');
SELECT pg_temp.ok(pg_temp.clean('income_filter', '{"campaign_id":"1","remove":["customers/6318538100/campaignCriteria/1~510001"]}')
  AND pg_temp.clean('income_filter', '{"ad_group_id":"5","remove":["customers/6318538100/adGroupCriteria/5~510001"]}')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","remove":["customers/1111111111/campaignCriteria/1~510001"]}', 'remove takes this account%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","remove":["customers/6318538100/adGroupCriteria/1~510001"]}', 'remove takes this account%')
  AND pg_temp.blocks('income_filter', '{"ad_group_id":"5","remove":["customers/6318538100/campaignCriteria/5~510001"]}', 'remove takes this account%')
  AND pg_temp.blocks('income_filter', '{"campaign_id":"1","remove":["customers/6318538100/campaignCriteria/1~510001'' OR 1=1"]}', 'remove takes this account%'),
  'PT17 letting a group back in takes only this account''s own rows at the same level');

-- owner only
SELECT pg_temp.ok((pg_temp.gop('campaign_create', pg_temp.camp())).status = 'pending'
  AND (pg_temp.gop('income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_0_50"]}')).status = 'pending', 'PT18 the owner''s own operations wait for approval as usual');
SELECT pg_temp.ok((pg_temp.gop('campaign_create', pg_temp.camp('{"name":"Agent idea"}'), 'agent')).status = 'pending'
  AND (pg_temp.gop('income_filter', '{"campaign_id":"24283129095","remove":["customers/6318538100/campaignCriteria/24283129095~510001"]}', 'agent')).status = 'pending'
  AND (pg_temp.gop('income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_60_70"]}', 'agent', 'approved')).status = 'pending'
  AND (pg_temp.gop('keyword_add', '{"ad_group_id":"5","keywords":[{"text":"cpl ground classes","match":"PHRASE"}]}', 'agent')).status = 'approved',
  'PT19 on Automatic an agent''s new campaign or income change still waits for the owner; its keyword still goes through');
SELECT pg_temp.ok((pg_temp.gop('campaign_geo', '{"campaign_id":"24283129095","add":["1007801"]}', 'agent')).status = 'pending'
  AND (pg_temp.gop('campaign_geo', '{"campaign_id":"24283129095","add":["1007802"]}', 'user')).status = 'pending', 'PT20 while targeting is locked an agent''s location change waits for the owner');
UPDATE public.ads_config SET value = 'off' WHERE key = 'google_targeting_locked';
SELECT pg_temp.ok((pg_temp.gop('campaign_geo', '{"campaign_id":"24283129095","add":["1007803"]}', 'agent')).status = 'approved'
  AND (pg_temp.gop('income_filter', '{"campaign_id":"24283129095","exclude":["INCOME_RANGE_70_80"]}', 'agent')).status = 'pending',
  'PT21 with the lock off agents change locations again; income and new campaigns stay the owner''s');
UPDATE public.ads_config SET value = 'on' WHERE key = 'google_targeting_locked';
-- the owner approves the agent's location change and the first new campaign
UPDATE public.ads_google_ops SET status = 'approved', approved_by = '00000000-0000-0000-0000-00000000000a', approved_at = now()
 WHERE (kind = 'campaign_geo' AND payload->'add' = '["1007801"]') OR (kind = 'campaign_create' AND payload->>'name' = 'WOA Search - Other cities');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.ads_google_ops WHERE status = 'approved' AND approved_by IS NOT NULL), 'PT22 the owner''s approval is never undone by the lock');
SELECT pg_temp.ok(pg_temp.blocks('campaign_create', pg_temp.camp('{"name":"A second one today"}'), '1 campaign(s) already created in the last 24 hours (limit 1).'),
  'PT23 one new campaign a day');

-- who runs what
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(v->>'kind' = 'campaign_create') FROM jsonb_array_elements(public.svc_ads_google_build_work()) v)
  AND (SELECT count(*) > 0 AND bool_and(v->>'kind' NOT IN ('campaign_create', 'income_filter')) FROM jsonb_array_elements(public.svc_ads_google_op_work()) v),
  'PT24 approved work is split: new kinds to ads-google-ops only, every other kind to ads-sync only');
UPDATE public.ads_config SET value = 'true' WHERE key = 'google_paused';
INSERT INTO public.ads_config (key, value) VALUES ('google_paused', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
SELECT pg_temp.ok(public.svc_ads_google_build_work() = '[]', 'PT25 Google paused: nothing of the new kinds is handed out');
UPDATE public.ads_config SET value = 'false' WHERE key = 'google_paused';
-- claimed just before sending: the gate runs again, so a limit lowered after approval stops the campaign
UPDATE public.ads_config SET value = '150' WHERE key = 'google_cap_daily';
CREATE TEMP TABLE claimed AS SELECT public.svc_ads_google_op_claim((SELECT id FROM public.ads_google_ops WHERE kind = 'campaign_create' AND status = 'approved')) c;
SELECT pg_temp.ok((SELECT NOT c FROM claimed)
  AND (SELECT status = 'stale' FROM public.ads_google_ops WHERE kind = 'campaign_create' AND payload->>'name' = 'WOA Search - Other cities'),
  'PT26 a daily limit lowered after approval stops the new campaign before anything is sent');
UPDATE public.ads_config SET value = '200' WHERE key = 'google_cap_daily';

-- what the AI team is told
SELECT pg_temp.ok((SELECT (length(value) - length(replace(value, 'Owner decisions (25 Nov 2026', ''))) / length('Owner decisions (25 Nov 2026') = 1
     AND value LIKE 'We One Aviation, pilot training institute in Dwarka, New Delhi.%' AND value LIKE '%top 10% and 11-20% household income%' FROM public.ads_config WHERE key = 'google_brand_facts'),
  'PT27 the owner''s decisions are added to the brand facts once (144 ran twice), after what was there');
SELECT pg_temp.ok((SELECT NOT active FROM public.ads_playbook WHERE evidence = 'old') AND (SELECT active FROM public.ads_playbook WHERE evidence = 'kept')
  AND (SELECT count(*) = 2 FROM public.ads_playbook),
  'PT28 the lesson naming the old location list is retired; no lesson is added and other lessons are untouched');
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_ads_google_build_work()', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.svc_ads_google_build_work()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.svc_ads_google_build_work()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'crm_private.ads_google_gate_v143(uuid,text,jsonb,uuid)', 'EXECUTE'), 'PT29 the work list is for the service only; the gates are private');
\echo ALL PREMIUM TESTS PASSED
