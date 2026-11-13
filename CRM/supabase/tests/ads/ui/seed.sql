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
