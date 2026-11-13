-- Google Ads operations + quality gate (migration 092). Runs after 10_ and 20_ in the same session.
RESET ROLE;
UPDATE public.ads_accounts SET status = 'connected' WHERE id = (SELECT v::uuid FROM ids WHERE k = 'ag');
CREATE OR REPLACE FUNCTION pg_temp.gop(p_kind text, p_payload jsonb, p_type text DEFAULT 'user') RETURNS public.ads_google_ops
LANGUAGE sql AS $$
  INSERT INTO public.ads_google_ops (account_id, kind, payload, created_by_type)
  VALUES ((SELECT v::uuid FROM ids WHERE k = 'ag'), p_kind, p_payload, p_type) RETURNING * $$;
CREATE OR REPLACE FUNCTION pg_temp.gate(p_kind text, p_payload jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT crm_private.ads_google_gate((SELECT v::uuid FROM ids WHERE k = 'ag'), p_kind, p_payload) $$;
CREATE OR REPLACE FUNCTION pg_temp.blocks(p_kind text, p_payload jsonb, p_like text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements_text(pg_temp.gate(p_kind, p_payload)->'blockers') m WHERE m ILIKE p_like) $$;
CREATE OR REPLACE FUNCTION pg_temp.clean(p_kind text, p_payload jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_array_length(pg_temp.gate(p_kind, p_payload)->'blockers') = 0 $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;

-- responsive search ads
SELECT pg_temp.ok(pg_temp.clean('rsa_create', '{"ad_group_id":"200162758466","final_url":"https://weoneaviation.in/cpl",
  "headlines":["Pilot Training in Delhi","DGCA Ground Classes Delhi","CPL Ground Classes"],"descriptions":["DGCA ground classes in Dwarka and online.","Send an enquiry; we explain fees and steps."],"path1":"pilot-training"}'),
  'O01 a clean responsive search ad passes the gate');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["Guaranteed DGCA Success","A b c","D e f"],"descriptions":["x y","z w"]}',
  '%claim "guarantee%'), 'O02 "Guaranteed DGCA Success" is blocked as an unprovable claim');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["98% Success Rate","A b c","D e f"],"descriptions":["x y","z w"]}',
  '%success rate%'), 'O03 "98% Success Rate" is blocked');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["Best Pilot Academy","A b c","D e f"],"descriptions":["x y","z w"]}',
  '%claim "best"%') AND pg_temp.clean('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["Bestow Wings Course","A b c","D e f"],"descriptions":["x y","z w"]}'),
  'O04 "best" is blocked as a whole word only ("Bestow" passes)');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["This headline is far longer than thirty","A b c","D e f"],"descriptions":["x y","z w"]}',
  '%over 30 characters%'), 'O05 headline over 30 characters blocked');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["Fly Now!","A b c","D e f"],"descriptions":["x y","z w"]}',
  '%"!"%'), 'O06 "!" in a headline blocked');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["Same","same","D e f"],"descriptions":["x y","z w"]}',
  '%all be different%'), 'O07 duplicate headlines blocked');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://applynow.weoneaviation.com/","headlines":["A b c","D e f","G h i"],"descriptions":["x y","z w"]}',
  '%Final URL%') AND pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"http://weoneaviation.in","headlines":["A b c","D e f","G h i"],"descriptions":["x y","z w"]}', '%Final URL%')
  AND pg_temp.clean('rsa_create', '{"ad_group_id":"1","final_url":"https://www.weoneaviation.in/x?a=1","headlines":["A b c","D e f","G h i"],"descriptions":["x y","z w"]}'),
  'O08 URL must be https on an allowed domain (www. subdomain ok; .com and http blocked)');
SELECT pg_temp.ok(pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["A b c","D e f"],"descriptions":["x y"]}', '%3-15 headlines%')
  AND pg_temp.blocks('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["A b c","D e f","G h i"],"descriptions":["x y"]}', '%2-4 descriptions%'),
  'O09 3-15 headlines and 2-4 descriptions required');

-- keywords and negatives
SELECT pg_temp.ok(pg_temp.blocks('keyword_add', '{"ad_group_id":"1","keywords":[{"text":"pilot training","match":"BROAD"}]}', '%broad match%')
  AND pg_temp.clean('keyword_add', '{"ad_group_id":"1","keywords":[{"text":"cpl ground classes","match":"PHRASE"},{"text":"dgca ground classes delhi","match":"EXACT"}]}'),
  'O10 new keywords must be phrase or exact');
SELECT pg_temp.ok(pg_temp.blocks('keyword_add', '{"ad_group_id":"1","keywords":[{"text":"pilot <course>","match":"EXACT"}]}', '%not allow%'), 'O11 invalid keyword characters blocked');
SELECT pg_temp.ok(pg_temp.blocks('negative_add', '{"level":"shared_set","shared_set_id":"11955185109","keywords":[{"text":"pilot","match":"BROAD"}]}', '%core search%')
  AND pg_temp.blocks('negative_add', '{"level":"campaign","campaign_id":"9","keywords":[{"text":"ground classes","match":"PHRASE"}]}', '%core search%')
  AND pg_temp.clean('negative_add', '{"level":"campaign","campaign_id":"9","keywords":[{"text":"cabin crew","match":"PHRASE"},{"text":"air hostess","match":"BROAD"},{"text":"pilot salary","match":"EXACT"}]}'),
  'O12 negatives that would block core searches are refused; others pass');

-- other kinds
SELECT pg_temp.ok(pg_temp.blocks('callout_add', '{"text":"100% Job Assistance"}', '%claim%') AND pg_temp.clean('callout_add', '{"text":"Free Career Counselling"}'),
  'O13 callouts are claim-checked');
SELECT pg_temp.ok(pg_temp.blocks('campaign_geo', '{"campaign_id":"1","target_type":"EVERYWHERE"}', '%PRESENCE%')
  AND pg_temp.clean('campaign_geo', '{"campaign_id":"1","target_type":"PRESENCE","add":["1007765"],"remove":["20466"]}')
  AND pg_temp.blocks('campaign_geo', '{"campaign_id":"1"}', '%Nothing to change%'), 'O14 location changes validated');
SELECT pg_temp.ok(pg_temp.blocks('keyword_status', '{"resource_name":"customers/9999999999/adGroupCriteria/1~2","status":"PAUSED"}', '%this account%')
  AND pg_temp.clean('keyword_status', '{"resource_name":"customers/1112223333/adGroupCriteria/1~2","status":"PAUSED"}'),
  'O15 status changes only for this account''s own resources');
SELECT pg_temp.ok(pg_temp.blocks('sitelink_add', '{"text":"Commercial Pilot License Course Delhi","final_url":"https://weoneaviation.in/cpl"}', '%1-25 characters%')
  AND pg_temp.clean('sitelink_add', '{"text":"DGCA Ground Classes","final_url":"https://weoneaviation.in/dgca","description1":"Classroom in Dwarka","description2":"Online batches too"}'),
  'O16 sitelinks validated');
SELECT pg_temp.ok(pg_temp.blocks('conversion_goal', '{"conversion_action_id":"5","primary":"yes"}', '%primary%') AND pg_temp.clean('conversion_goal', '{"conversion_action_id":"5","primary":false}'),
  'O17 conversion goal change validated');
SELECT pg_temp.ok(pg_temp.blocks('ad_group_create', '{"campaign_id":"1","name":"DGCA Ground Classes","cpc_bid":500}', '%CPC bid%')
  AND pg_temp.clean('ad_group_create', '{"campaign_id":"1","name":"DGCA Ground Classes","cpc_bid":40}'), 'O18 ad group CPC bid capped');

-- lifecycle: user ops wait for an approver; agent ops auto-approve only in Autopilot 'auto' and only when clean
SET ROLE authenticated; SELECT pg_temp.as_('c');
INSERT INTO ids SELECT 'op1', (public.api_ads_google_op_create((SELECT v::uuid FROM ids WHERE k = 'ag'), 'callout_add', '{"text":"Free Career Counselling"}', 'Add callout')->>'id')::uuid;
SELECT pg_temp.ok((SELECT status FROM jsonb_to_recordset(public.api_ads_google_ops()) AS x(id uuid, status text) WHERE id = (SELECT v::uuid FROM ids WHERE k = 'op1')) = 'pending',
  'O19 a user operation waits as pending');
SELECT pg_temp.ok(public.api_ads_google_op_create((SELECT v::uuid FROM ids WHERE k = 'ag'), 'callout_add', '{"text":"Guaranteed Selection"}')->>'status' = 'blocked',
  'O20 an operation that fails the gate is saved as blocked');
SELECT pg_temp.fails(format($$SELECT public.api_ads_google_op_decide('%s', true)$$, (SELECT v FROM ids WHERE k = 'op1')), '%cannot approve%', 'O21 a viewer cannot approve');
SELECT pg_temp.as_('d');
SELECT pg_temp.ok(public.api_ads_google_op_decide((SELECT v::uuid FROM ids WHERE k = 'op1'), true)->>'status' = 'approved', 'O22 an approver approves');
SELECT pg_temp.fails($$SELECT public.svc_ads_google_op_work()$$, '%permission denied%', 'O23 the browser cannot reach the executor functions');
SELECT pg_temp.fails($$SELECT * FROM public.ads_google_ops$$, '%permission denied%', 'O24 the operations table is not readable directly');
RESET ROLE;
SELECT pg_temp.ok((pg_temp.gop('callout_add', '{"text":"Flexible Payment Plans"}', 'agent')).status = 'pending', 'O25 Autopilot off: agent operations wait as pending');
UPDATE public.ads_config SET value = 'auto' WHERE key = 'autopilot_google';
SELECT pg_temp.ok((pg_temp.gop('callout_add', '{"text":"Classes in Dwarka"}', 'agent')).status = 'approved'
  AND (pg_temp.gop('callout_add', '{"text":"No.1 Academy"}', 'agent')).status = 'blocked'
  AND (pg_temp.gop('callout_add', '{"text":"Online Batches"}', 'user')).status = 'pending',
  'O26 Autopilot auto: clean agent ops approve themselves; failing ones stay blocked; user ops still need an approver');

-- executor: claim re-runs the gate; finish records the outcome
SET ROLE service_role;
SELECT pg_temp.ok(jsonb_array_length(public.svc_ads_google_op_work()) >= 2, 'O27 executor sees approved operations');
SELECT pg_temp.ok(public.svc_ads_google_op_claim((SELECT v::uuid FROM ids WHERE k = 'op1')) AND NOT public.svc_ads_google_op_claim((SELECT v::uuid FROM ids WHERE k = 'op1')),
  'O28 an operation is claimed once');
SELECT public.svc_ads_google_op_finish((SELECT v::uuid FROM ids WHERE k = 'op1'), 'verified', NULL, '{"resource_names":["customers/1112223333/assets/1"]}', '{"found":1}');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'verified' AND verify_result->>'found' = '1' FROM public.ads_google_ops WHERE id = (SELECT v::uuid FROM ids WHERE k = 'op1'))
  AND EXISTS (SELECT 1 FROM public.ads_activity_log WHERE action = 'google_op_verified'), 'O29 verified outcome stored and logged');
INSERT INTO ids SELECT 'op2', (pg_temp.gop('rsa_create', '{"ad_group_id":"1","final_url":"https://weoneaviation.in","headlines":["A b c","D e f","G h i"],"descriptions":["x y","z w"]}', 'agent')).id;
UPDATE public.ads_config SET value = 'example.org' WHERE key = 'google_allowed_domains';
SET ROLE service_role;
SELECT pg_temp.ok(NOT public.svc_ads_google_op_claim((SELECT v::uuid FROM ids WHERE k = 'op2')), 'O30 claim refuses an operation a check now blocks');
RESET ROLE;
SELECT pg_temp.ok((SELECT status FROM public.ads_google_ops WHERE id = (SELECT v::uuid FROM ids WHERE k = 'op2')) = 'stale', 'O31 ...and marks it stale');
UPDATE public.ads_config SET value = 'weoneaviation.in' WHERE key = 'google_allowed_domains';
UPDATE public.ads_config SET value = 'true' WHERE key = 'execution_paused';
SET ROLE service_role;
SELECT pg_temp.ok(public.svc_ads_google_op_work() = '[]'::jsonb, 'O32 emergency stop: the executor gets nothing');
RESET ROLE;
UPDATE public.ads_config SET value = 'false' WHERE key = 'execution_paused';
UPDATE public.ads_rules SET value = '{"max": 2}' WHERE code = 'g_ops_per_day';
SELECT pg_temp.ok(pg_temp.blocks('callout_add', '{"text":"Weekend Batches"}', '%last 24 hours%'), 'O33 daily operation limit enforced');
UPDATE public.ads_config SET value = 'off' WHERE key = 'autopilot_google';

\echo ALL ADS GOOGLE OPS TESTS PASSED
