-- 127: an ad creative ordered from a strategy carries the plan's format, hook, outline, facts to verify, length and script
-- (CB01-CB02). Runs after 10_ (strategy 77, approver 'd').
\set QUIET on
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF;
  RAISE NOTICE 'PASS %', name;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000' || who, false) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon, service_role;
SET client_min_messages = notice;
INSERT INTO public.ads_meta_strategy_version (strategy_id, version, plan) VALUES (77, 2, '{"creatives": [
  {"key": "v5", "name": "NIOS route", "format": "video", "headline": "PCM nahi li?", "primary_text": "NIOS se Physics & Maths", "visual_brief": "Presenter, 1080x1920",
   "persona": "student", "angle": "eligibility", "cta": "SIGN_UP", "hook": "12th mein PCM nahi thi?", "outline": ["Hook", "NIOS route", "CTA"],
   "facts_to_verify": ["DGCA CPL needs Physics and Maths in class 12"], "est_seconds": 38,
   "script": [{"t": "0-3s", "line": "12th mein PCM nahi thi?"}, {"t": "3-30s", "line": "NIOS se Physics aur Maths"}]},
  {"key": "i1", "name": "Card", "format": "image", "headline": "x", "primary_text": "y", "visual_brief": "z", "est_seconds": "20", "outline": "not a list"}]}')
ON CONFLICT DO NOTHING;
UPDATE public.ads_meta_strategy SET approved_version = 2, version = 2 WHERE id = 77;
SELECT pg_temp.as_('d'); SET ROLE authenticated;
SELECT public.api_content_from_strategy(77); SELECT public.api_content_from_strategy(77);
RESET ROLE;
SELECT pg_temp.ok((SELECT brief->>'format' = 'video' AND brief->>'hook' = '12th mein PCM nahi thi?' AND brief->'outline' = '["Hook", "NIOS route", "CTA"]'
      AND brief->'facts_to_verify'->>0 LIKE 'DGCA CPL%' AND brief->'est_seconds' = '38' AND jsonb_array_length(brief->'script') = 2
      AND brief->'script'->0->>'line' = '12th mein PCM nahi thi?' AND brief->>'headline' = 'PCM nahi li?' AND brief->'sizes' = '["1080x1920"]'
    FROM public.content_item WHERE strategy_id = 77 AND creative_key = 'v5' AND kind = 'ad_video'),
  'CB01 a video ad brief carries format, hook, outline, facts to verify, est_seconds and the approved script (116 fields kept)');
SELECT pg_temp.ok((SELECT brief->'est_seconds' = '20' AND NOT brief ? 'outline' AND NOT brief ? 'script' AND NOT brief ? 'hook' AND brief->>'format' = 'image'
    FROM public.content_item WHERE strategy_id = 77 AND creative_key = 'i1' AND kind = 'ad_image')
    AND (SELECT count(*) = 1 FROM public.content_item WHERE strategy_id = 77 AND creative_key = 'v5'),
  'CB02 only fields in the right shape are copied (an outline that is not a list is left out); ordering twice makes one item');
\echo ALL CONTENT BRIEF TESTS PASSED
