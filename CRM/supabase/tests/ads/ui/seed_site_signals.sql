-- UI seed for 108 (Website signals): a connected site with Search Console and GA4 totals and a firing Pixel.
UPDATE public.ads_config SET value = 'sc-domain:weoneaviation.in' WHERE key = 'site_gsc_url';
UPDATE public.ads_config SET value = '123456789' WHERE key = 'site_ga4_property';
UPDATE public.ads_config SET value = '{"id": "555666777", "name": "We One Pixel", "firing": true}' WHERE key = 'meta_pixel';
INSERT INTO public.ads_site_row (src, kind, k1, k2, win, m) VALUES
  ('gsc', 'query', 'pilot training fees delhi', '', 'cur', '{"clicks": 30, "impressions": 900, "position": 6.1}'),
  ('gsc', 'query', 'pilot training fees delhi', '', 'prev', '{"clicks": 20, "impressions": 400, "position": 8}'),
  ('gsc', 'query', 'how to become pilot after 12th', '', 'cur', '{"clicks": 5, "impressions": 700, "position": 12}'),
  ('gsc', 'query', 'dgca ground classes', '', 'cur', '{"clicks": 12, "impressions": 150, "position": 4}'),
  ('gsc', 'page', 'https://weoneaviation.in/fees', '', 'cur', '{"clicks": 25, "impressions": 800}'),
  ('ga', 'landing', '/fees', '', 'cur', '{"sessions": 200, "engagedSessions": 120, "keyEvents": 9}'),
  ('ga', 'channel', 'Organic Search', '', 'cur', '{"sessions": 500, "engagedSessions": 300, "keyEvents": 14}'),
  ('ga', 'city', 'Delhi', 'Delhi', 'cur', '{"activeUsers": 260, "keyEvents": 8}'),
  ('ga', 'event', 'form_start', '', 'cur', '{"eventCount": 70}')
ON CONFLICT DO NOTHING;
