-- UI test data for Meta Ads > Insights (migration 103): two campaigns, ads with creative, 60 days of numbers, breakdowns,
-- Meta Ads leads at different stages. Its own client and Meta account, so the other UI checks' numbers do not change.
INSERT INTO public.ads_clients (id, name, crm_segment) VALUES ('30000000-0000-0000-0000-000000000009', 'Insights Demo', 'aviation');
INSERT INTO public.ads_accounts (id, client_id, platform, external_id, name, currency, timezone, status, created_at) VALUES
  ('31000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-000000000009', 'meta', '564511644492586', 'Insights Meta', 'INR', 'Asia/Kolkata', 'connected', now() + interval '1 day');
INSERT INTO public.ads_campaigns (account_id, external_id, name, status) VALUES
  ('31000000-0000-0000-0000-000000000009', '7101', 'CPL Reels Delhi', 'ENABLED'), ('31000000-0000-0000-0000-000000000009', '7102', 'Broad India Static', 'PAUSED');
INSERT INTO public.ads_meta_object (account_id, level, external_id, campaign_ext, adset_ext, name, status, info) VALUES
  ('31000000-0000-0000-0000-000000000009', 'campaign', '7101', NULL, NULL, 'CPL Reels Delhi', 'ACTIVE', '{"objective": "OUTCOME_LEADS"}'),
  ('31000000-0000-0000-0000-000000000009', 'campaign', '7102', NULL, NULL, 'Broad India Static', 'PAUSED', '{}'),
  ('31000000-0000-0000-0000-000000000009', 'adset', '8101', '7101', NULL, 'Delhi 18-24', 'ACTIVE', '{"age_min": 18, "age_max": 24, "genders": ["all"], "cities": ["New Delhi"]}'),
  ('31000000-0000-0000-0000-000000000009', 'adset', '8102', '7102', NULL, 'India 25-45', 'PAUSED', '{"age_min": 25, "age_max": 45, "genders": ["all"], "countries": ["IN"]}'),
  ('31000000-0000-0000-0000-000000000009', 'ad', '9101', '7101', '8101', 'Pilot banna hai? Reel', 'ACTIVE', '{"format": "video", "body": "Pilot banna hai? DGCA ground classes in Delhi", "cta": "SIGN_UP", "form_id": "555000111"}'),
  ('31000000-0000-0000-0000-000000000009', 'ad', '9102', '7102', '8102', 'Fees banner', 'PAUSED', '{"format": "image", "body": "CPL fees from 45 lakh. Apply now", "cta": "LEARN_MORE"}')
ON CONFLICT (level, external_id) DO NOTHING;
INSERT INTO public.ads_meta_ad_day (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks, leads)
SELECT '31000000-0000-0000-0000-000000000009', a.ad, a.adset, a.camp, current_date - g, a.spend, a.imp, a.clk, a.leads
  FROM generate_series(1, 150) g,
       (VALUES ('9101', '8101', '7101', 800, 9000, 160, 4), ('9102', '8102', '7102', 2200, 15000, 90, 2)) a(ad, adset, camp, spend, imp, clk, leads)
ON CONFLICT DO NOTHING;
INSERT INTO public.ads_meta_breakdown (account_id, kind, month, k1, k2, spend, impressions, clicks, leads) VALUES
  ('31000000-0000-0000-0000-000000000009', 'age_gender', date_trunc('month', current_date)::date, '18-24', 'male', 30000, 300000, 5000, 150),
  ('31000000-0000-0000-0000-000000000009', 'age_gender', date_trunc('month', current_date)::date, '35-44', 'female', 20000, 200000, 900, 12),
  ('31000000-0000-0000-0000-000000000009', 'region', date_trunc('month', current_date)::date, 'Delhi', '', 40000, 400000, 5000, 140),
  ('31000000-0000-0000-0000-000000000009', 'hour', date_trunc('month', current_date)::date, '21', '', 5000, 50000, 900, 40)
ON CONFLICT DO NOTHING;
INSERT INTO public.ads_lead (pipeline, name, phone_e164, stage, first_touch, last_touch, created_at)
SELECT 'pilot_training', 'Insights ' || g, '+9198116' || lpad(g::text, 5, '0'),
       CASE WHEN g % 10 = 0 THEN 'admission_completed' WHEN g % 3 = 0 THEN 'qualified' ELSE 'contacted' END,
       jsonb_build_object('fbclid', 'fb.' || g, 'meta_source', 'instant_form', 'ad_id', CASE WHEN g % 4 = 0 THEN '9102' ELSE '9101' END,
         'adset_id', CASE WHEN g % 4 = 0 THEN '8102' ELSE '8101' END, 'utm_campaignid', CASE WHEN g % 4 = 0 THEN '7102' ELSE '7101' END),
       '{}'::jsonb, now() - make_interval(days => g)
  FROM generate_series(1, 120) g;
INSERT INTO public.ads_config (key, value) VALUES ('meta_history_cursor', to_char(current_date + 40, 'YYYY-MM-01')), ('meta_history_done_at', now()::text)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
