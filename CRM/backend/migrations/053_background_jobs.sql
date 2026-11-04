-- 053: Background jobs on Supabase (pg_cron), replacing the Render schedulers.
--
--  * Mongo import (website popup / contact-form leads stored in MongoDB Atlas): every minute pg_cron
--    calls the crm-mongo-import Edge Function, which reads new documents and hands them to
--    svc_mongo_import below (all writes in one transaction).
--  * Attendance retention: 1st of every month, archive raw punches older than 3 months, then purge.
--
-- Both jobs use the same job_lease rows as the Render backend ('mongo_import', 'attendance_retention').
-- While Render is alive it keeps renewing its lease, so these jobs simply skip; when Render is switched
-- off its lease expires and Supabase takes over within ~2.5 minutes. No double imports, no gap.
--
-- Not ported: Render's SLA check only wrote log lines (nothing visible in the app) and the self-ping
-- only kept Render awake.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS public.job_lease (name text PRIMARY KEY, holder text, lease_until timestamptz);
ALTER TABLE public.job_lease ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.job_lease FROM anon, authenticated;

-- Same rule as backend/job_lease.py: renew your own lease, or take an expired one.
CREATE OR REPLACE FUNCTION crm_private.take_lease(p_name text, p_seconds int) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH t AS (
    INSERT INTO public.job_lease (name, holder, lease_until)
    VALUES (p_name, 'supabase', now() + make_interval(secs => p_seconds))
    ON CONFLICT (name) DO UPDATE SET holder = EXCLUDED.holder, lease_until = EXCLUDED.lease_until
      WHERE public.job_lease.lease_until < now() OR public.job_lease.holder = EXCLUDED.holder
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM t)
$$;

-- ===========================================================================================
-- Mongo import (port of mongo_bridge.py)
-- ===========================================================================================
CREATE TABLE IF NOT EXISTS public.mongo_import_watermark (
  id serial PRIMARY KEY, collection_name text UNIQUE NOT NULL, last_imported_at timestamptz,
  last_imported_id text, updated_at timestamptz DEFAULT now());

-- Called first by the Edge Function (after it has connected to MongoDB): takes the lease and
-- returns the watermark. ok=false -> another runner (Render) holds the lease; do nothing.
CREATE OR REPLACE FUNCTION crm_private.mongo_begin() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w record;
BEGIN
  IF NOT crm_private.take_lease('mongo_import', 150) THEN RETURN jsonb_build_object('ok', false); END IF;
  INSERT INTO public.mongo_import_watermark (collection_name) VALUES ('website_leads') ON CONFLICT (collection_name) DO NOTHING;
  SELECT m.last_imported_at, m.last_imported_id INTO w FROM public.mongo_import_watermark m WHERE m.collection_name = 'website_leads';
  RETURN jsonb_build_object('ok', true, 'last_imported_at', w.last_imported_at, 'last_imported_id', w.last_imported_id);
END $$;

-- docs: [{_id, name, phone, email, course, message, source, createdAt}] in createdAt order.
CREATE OR REPLACE FUNCTION crm_private.mongo_import(p_docs jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d jsonb; ph text; src text; med text; camp text; nm text; em text; course text; msg text;
        ex uuid; imported int := 0; deduped int := 0; skipped int := 0; failed int := 0;
        last_ts timestamptz; last_id text; w_ts timestamptz;
BEGIN
  SELECT m.last_imported_at INTO w_ts FROM public.mongo_import_watermark m WHERE m.collection_name = 'website_leads';
  FOR d IN SELECT value FROM jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) LOOP
    BEGIN
      -- watermark follows every document read, imported or not (as before)
      IF nullif(d->>'createdAt', '') IS NOT NULL THEN
        last_ts := (d->>'createdAt')::timestamptz; last_id := d->>'_id';
      END IF;
      IF length(regexp_replace(coalesce(d->>'phone', ''), '\D', '', 'g')) < 7 THEN
        skipped := skipped + 1; CONTINUE;          -- no usable phone number
      END IF;
      ph := crm_private.norm_phone(d->>'phone');
      src := coalesce(d->>'source', '');
      med := nullif(btrim(split_part(src, ' - ', 1)), '');
      camp := CASE WHEN position(' - ' IN src) > 0 THEN nullif(btrim(substr(src, position(' - ' IN src) + 3)), '') END;
      nm := nullif(btrim(coalesce(d->>'name', '')), '');
      em := nullif(lower(btrim(coalesce(d->>'email', ''))), '');
      course := coalesce(nullif(d->>'course', ''), 'General Inquiry');
      msg := nullif(btrim(coalesce(d->>'message', '')), '');

      PERFORM pg_advisory_xact_lock(hashtext('lead|' || ph));
      SELECT l.id INTO ex FROM public.lead l WHERE l.dedup_key = ph;
      IF FOUND THEN
        UPDATE public.lead SET name = coalesce(nm, name), email = coalesce(em, email),
          -- a form without a course must not wipe the course already on the lead
          course_interest = coalesce(nullif(d->>'course', ''), course_interest), address = coalesce(msg, address),
          utm_source = 'website', utm_medium = coalesce(med, utm_medium), utm_campaign = coalesce(camp, utm_campaign)
        WHERE id = ex;
        deduped := deduped + 1;
      ELSE
        INSERT INTO public.lead (name, phone, email, course_interest, address, utm_source, utm_medium, utm_campaign, dedup_key, status)
        VALUES (coalesce(nm, ''), ph, em, course, msg, 'website', med, camp, ph, 'new');
        imported := imported + 1;
      END IF;
    EXCEPTION WHEN others THEN
      failed := failed + 1;
      RAISE WARNING 'mongo import: document % failed: %', d->>'_id', SQLERRM;
    END;
  END LOOP;

  IF last_ts IS NOT NULL AND last_ts IS DISTINCT FROM w_ts THEN
    UPDATE public.mongo_import_watermark SET last_imported_at = last_ts, last_imported_id = last_id, updated_at = now()
     WHERE collection_name = 'website_leads';
  END IF;
  IF imported > 0 OR deduped > 0 THEN
    INSERT INTO public.audit_log (actor, action, entity, payload)
    VALUES (NULL, 'mongo_import', 'lead', jsonb_build_object('imported', imported, 'deduped', deduped,
            'last_timestamp', last_ts, 'runner', 'supabase'));
  END IF;
  RETURN jsonb_build_object('imported', imported, 'deduped', deduped, 'skipped', skipped, 'failed', failed,
                            'last_timestamp', last_ts);
END $$;

-- ===========================================================================================
-- Attendance retention with the shared lease
-- ===========================================================================================
CREATE OR REPLACE FUNCTION crm_private.attendance_retention_job() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.take_lease('attendance_retention', 6 * 3600) THEN
    RETURN jsonb_build_object('skipped', 'another runner holds the lease');
  END IF;
  RETURN crm_private.attendance_retention();
END $$;

-- ===========================================================================================
-- Token the scheduler uses to call the import function, and service wrappers
-- ===========================================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_cron_token') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'crm_cron_token',
                                'Token pg_cron sends to the crm-mongo-import Edge Function');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_cron_token_ok(token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.token_ok('crm_cron_token', token) $$;
CREATE OR REPLACE FUNCTION public.svc_mongo_begin() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.mongo_begin() $$;
CREATE OR REPLACE FUNCTION public.svc_mongo_import(docs jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.mongo_import(docs) $$;

REVOKE ALL ON FUNCTION crm_private.take_lease(text, int), crm_private.mongo_begin(), crm_private.mongo_import(jsonb),
  crm_private.attendance_retention_job() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.svc_cron_token_ok(text), public.svc_mongo_begin(), public.svc_mongo_import(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_cron_token_ok(text), public.svc_mongo_begin(), public.svc_mongo_import(jsonb) TO service_role;

-- ===========================================================================================
-- Schedules (UTC). Re-running this migration replaces them.
-- ===========================================================================================
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('crm-mongo-import', 'crm-attendance-retention');

SELECT cron.schedule('crm-mongo-import', '* * * * *', $job$
  SELECT net.http_post(
    url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/crm-mongo-import',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000)
$job$);

-- 02:00 IST on the 1st (20:30 UTC on the last day of the month is awkward in cron, so 02:00 UTC = 07:30 IST)
SELECT cron.schedule('crm-attendance-retention', '0 2 1 * *', $job$ SELECT crm_private.attendance_retention_job() $job$);
