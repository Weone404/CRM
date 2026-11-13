-- UI test data only (local throwaway database). Not real performance.
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a','Test Admin','Admin','10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b','Test Sales','Sales','10000000-0000-0000-0000-00000000000b');
INSERT INTO public.ads_clients (id, name, crm_segment, target_cpl, gross_margin_pct, max_daily_budget, monthly_budget)
VALUES ('30000000-0000-0000-0000-000000000001', 'Test Client A', 'aviation', 800, 40, 5000, 60000);
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, utm_source, status, last_ok_at, last_sync_at) VALUES
  ('31000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','google','1112223333','Test Google','INR','Asia/Kolkata','google','connected', now(), now()),
  ('31000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001','meta','998877','Test Meta','INR','Asia/Kolkata','facebook','auth_required', NULL, now());
UPDATE public.ads_accounts SET last_error = 'Session has expired (test)' WHERE external_id = '998877';
INSERT INTO public.ads_campaigns (id, account_id, external_id, name, status, daily_budget, budget_ref, utm_campaign, synced_at) VALUES
  ('32000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000001','g1','Test Search','ENABLED',1000,'customers/1112223333/campaignBudgets/9','test_search', now()),
  ('32000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000002','m1','Test Lead Form','PAUSED',500,'campaign',NULL, now());
INSERT INTO public.ads_metrics_daily (campaign_id, day, impressions, clicks, spend, conversions, conversion_value)
SELECT '32000000-0000-0000-0000-000000000001', (now() AT TIME ZONE 'Asia/Kolkata')::date - g, 1000, 40, 900, 2, 0 FROM generate_series(1, 10) g;
INSERT INTO public.lead (name, utm_source, utm_campaign, segment, created_at, is_eligible)
SELECT 'Test Lead ' || g, 'google', 'test_search', 'aviation', now() - make_interval(days => g), g % 2 = 0 FROM generate_series(1, 6) g;

-- 091: Google's delivery verdict on the enabled campaign
UPDATE public.ads_campaigns SET raw = jsonb_build_object('primary_status','LIMITED','primary_status_reasons',jsonb_build_array('BUDGET_CONSTRAINED','SEARCH_VOLUME_LIMITED'),'serving_status','SERVING')
 WHERE id = '32000000-0000-0000-0000-000000000001';

-- 093: Autopilot test data (a geo suggestion with options, a reviewer rejection, an agent change that went live)
INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal) VALUES
  ('31000000-0000-0000-0000-000000000001', 'geo', 'Target these cities', 'Past enquiries came mostly from these cities (test data).',
   '{"ops": [{"kind": "campaign_geo", "payload": {"campaign_id": "111", "add": ["1007765"]}, "option": "1007765", "summary": "Gurugram"},
             {"kind": "campaign_geo", "payload": {"campaign_id": "111", "add": ["1007826"]}, "option": "1007826", "summary": "Noida"},
             {"kind": "campaign_geo", "payload": {"campaign_id": "111", "target_type": "PRESENCE"}, "summary": "Only people located there"}],
     "options": [{"id": "1007765", "label": "Gurugram", "reason": "12 enquiries"}, {"id": "1007826", "label": "Noida", "reason": "3 enquiries", "selected": false}]}');
INSERT INTO public.ads_agent_runs (account_id, role, job, status, attempt, summary) VALUES
  ('31000000-0000-0000-0000-000000000001', 'reviewer', 'review_ad', 'rejected', 1, 'Headline "Guaranteed DGCA Success" is an unprovable claim (test)'),
  ('31000000-0000-0000-0000-000000000001', 'researcher', 'research', 'done', 1, 'Found 40 keyword ideas (test)');
INSERT INTO public.ads_google_ops (account_id, kind, payload, summary, created_by_type, status) VALUES
  ('31000000-0000-0000-0000-000000000001', 'callout_add', '{"text": "Weekend Batches"}', 'Add callout "Weekend Batches" (test)', 'agent', 'approved');
UPDATE public.ads_google_ops SET status = 'verified' WHERE summary LIKE 'Add callout "Weekend Batches"%';
UPDATE public.ads_config SET value = '5000' WHERE key = 'google_cap_daily';
UPDATE public.ads_config SET value = '152000' WHERE key = 'google_cap_monthly';

-- worst-case UI tests: an ADS viewer who cannot approve, and a second open suggestion
INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000c','Test Viewer','Sales','10000000-0000-0000-0000-00000000000c');
INSERT INTO public.ads_access (employee_id, can_approve) VALUES ('00000000-0000-0000-0000-00000000000c', false);
INSERT INTO public.ads_autopilot_suggestions (account_id, kind, title, reason, proposal) VALUES
  ('31000000-0000-0000-0000-000000000001', 'assets', 'Add a callout', 'Test: two people accept at once.',
   '{"ops": [{"kind": "callout_add", "payload": {"text": "Online Classes"}, "summary": "Callout Online Classes"}]}');

-- 096: a daily report, two lessons, and the agents helper checked in just now
INSERT INTO public.ads_agent_runs (account_id, role, job, status, summary, output, finished_at) VALUES
  ('31000000-0000-0000-0000-000000000001', 'supervisor', 'daily_report', 'done',
   '12 Nov: spent 900, 40 clicks, 2 CRM leads (450 per lead). This month 9000 of 15200.', '{"day": "2026-11-12"}', now());
INSERT INTO public.ads_playbook (lesson, evidence) VALUES
  ('Put the website source next to every fact in research', 'Reviewer rejected a true fact it could not see (13 Nov)'),
  ('Keep proposals under 25 changes', 'Builder failed 3 times on a big audit');
INSERT INTO public.ads_config (key, value) VALUES ('agents_last_seen', now()::text) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
