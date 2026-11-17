-- UI seed for 106 (Lead quality and lead score): the 120 Insights leads get archive rows with form answers, plus two new
-- leads still waiting for a first call (scored as they arrive).
INSERT INTO public.ads_meta_lead_archive (external_id, source, created_time, form_id, form_name, campaign_id, campaign_name, ad_id, platform, name, answers, ads_lead_id)
SELECT '91' || lpad(row_number() OVER (ORDER BY l.created_at)::text, 10, '0'), 'csv', l.created_at, '6101', 'CPL enquiry', l.first_touch->>'utm_campaignid',
       CASE WHEN l.first_touch->>'utm_campaignid' = '7102' THEN 'CPL Jaipur' ELSE 'CPL Delhi' END, l.first_touch->>'ad_id',
       CASE WHEN extract(day FROM l.created_at)::int % 2 = 0 THEN 'ig' ELSE 'fb' END, l.name,
       jsonb_build_object('class_12_with_maths_and_physics?', CASE WHEN l.stage IN ('qualified', 'admission_completed') THEN 'Yes' ELSE 'No' END,
                          'city', CASE WHEN l.first_touch->>'utm_campaignid' = '7102' THEN 'Jaipur' ELSE 'Delhi' END), l.id
  FROM public.ads_lead l WHERE l.name LIKE 'Insights %'
ON CONFLICT (external_id) DO NOTHING;
UPDATE public.ads_config SET value = (now() - interval '1 day')::text WHERE key = 'lead_alert_since';
WITH n AS (
  INSERT INTO public.ads_lead (pipeline, name, phone_e164, stage, first_touch, last_touch, created_at)
  VALUES ('pilot_training', 'Hot Prospect', '+919811600901', 'lead_created', '{"fbclid": "fb.h", "meta_source": "instant_form", "ad_id": "9101", "utm_campaignid": "7101"}', '{}', now() - interval '20 minutes'),
         ('pilot_training', 'Cold Prospect', '+919811600902', 'lead_created', '{"fbclid": "fb.c", "meta_source": "instant_form", "ad_id": "9102", "utm_campaignid": "7102"}', '{}', now() - interval '25 minutes')
  RETURNING id, name, created_at, first_touch)
INSERT INTO public.ads_meta_lead_archive (external_id, source, created_time, form_id, form_name, campaign_id, campaign_name, ad_id, platform, name, answers, ads_lead_id)
SELECT CASE WHEN n.name = 'Hot Prospect' THEN '920000000001' ELSE '920000000002' END, 'crm', n.created_at, '6101', 'CPL enquiry', n.first_touch->>'utm_campaignid',
       CASE WHEN n.name = 'Hot Prospect' THEN 'CPL Delhi' ELSE 'CPL Jaipur' END, n.first_touch->>'ad_id', 'ig', n.name,
       jsonb_build_object('class_12_with_maths_and_physics?', CASE WHEN n.name = 'Hot Prospect' THEN 'Yes' ELSE 'No' END), n.id
  FROM n;
