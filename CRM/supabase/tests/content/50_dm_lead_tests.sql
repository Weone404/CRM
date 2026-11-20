-- 123 Instagram DM leads: DL01-DL04.
\set QUIET on
SET client_min_messages = notice;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', name; END IF; RAISE NOTICE 'PASS %', name; END $$;
-- the website intake (052) as it behaves: one lead per phone
ALTER TABLE public.lead ADD COLUMN IF NOT EXISTS utm_source text, ADD COLUMN IF NOT EXISTS utm_medium text, ADD COLUMN IF NOT EXISTS utm_campaign text,
  ADD COLUMN IF NOT EXISTS dedup_key text, ADD COLUMN IF NOT EXISTS last_note text;
DO $$ BEGIN
IF to_regprocedure('crm_private.ingest_website_lead(jsonb)') IS NULL THEN
  EXECUTE $f$CREATE FUNCTION crm_private.ingest_website_lead(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $b$
    DECLARE lid uuid; BEGIN
      SELECT id INTO lid FROM public.lead WHERE dedup_key = right(p->>'phone', 10);
      IF FOUND THEN RETURN jsonb_build_object('status', 'duplicate', 'lead_id', lid); END IF;
      INSERT INTO public.lead (name, phone, course_interest, utm_source, utm_medium, utm_campaign, dedup_key)
      VALUES (p->>'name', p->>'phone', p->>'course_interest', p->>'utm_source', p->>'utm_medium', p->>'utm_campaign', right(p->>'phone', 10)) RETURNING id INTO lid;
      RETURN jsonb_build_object('status', 'created', 'lead_id', lid); END $b$ $f$;
END IF; END $$;
CREATE TEMP TABLE dl AS SELECT public.svc_content_dm_lead('{"username": "kabir_01", "phone": "+919811122333", "source": "comment_dm", "text": "PDF please"}') r;
SELECT pg_temp.ok((SELECT r->>'status' = 'created' FROM dl) AND (SELECT name = '@kabir_01' AND utm_source = 'instagram' AND utm_medium = 'comment_dm' AND utm_campaign = 'instagram_dm'
    AND course_interest = 'CPL (Instagram)' AND last_note = 'Instagram @kabir_01: "PDF please"' FROM public.lead WHERE phone = '+919811122333'),
  'DL01 a phone number from an Instagram chat becomes a lead, named by the handle, with what they wrote for the call');
SELECT pg_temp.ok((public.svc_content_dm_lead('{"username": "kabir_01", "phone": "+919811122333", "source": "dm"}')->>'status') = 'duplicate'
    AND (SELECT count(*) = 1 FROM public.lead WHERE phone = '+919811122333'), 'DL02 the same number is never filed twice');
SELECT pg_temp.ok((public.svc_content_dm_lead('{"username": "x", "phone": "12345"}') ? 'error'), 'DL03 a number that is not an Indian mobile is refused');
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.svc_content_dm_lead(jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.svc_content_dm_lead(jsonb)', 'EXECUTE'), 'DL04 only crm-content (service role) can file these');
\echo ALL DM LEAD TESTS PASSED
