-- What the live database holds before 144: the owner's facts for the AI team and the lesson that names the old location list.
INSERT INTO public.ads_config (key, value) VALUES ('google_brand_facts', 'We One Aviation, pilot training institute in Dwarka, New Delhi.')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO public.ads_playbook (lesson, evidence, active) VALUES
  ('Before saying a place will or will not get ads, check it against the campaign''s location list, which includes all of Punjab and Delhi plus Faridabad.', 'old', true),
  ('Never send more than 25 operations in one proposal.', 'kept', true);
