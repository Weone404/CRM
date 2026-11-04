-- 052: Policy documents, course quotes (PDF), and website lead intake on Supabase.
--
-- Found while porting (both never worked on the live database):
--   * policy_doc has no created_by column, so creating a document on Render always failed;
--   * Render's quote generator reads course.discount_percent / down_payment, which do not exist.
-- Here: policy_doc gets created_by; a quote takes its discount, instalments and down payment per
-- quote (stored with the quote) instead of overwriting the course for everyone.
-- Quote PDFs are built by the crm-quotes Edge Function and kept in the private "quotes" bucket.
-- Website leads arrive through the crm-leads Edge Function (public intake + Book My Charter token).

-- ===========================================================================================
-- POLICY DOCS (every employee reads and adds, as before)
-- ===========================================================================================
ALTER TABLE public.policy_doc ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.employee(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.api_policy_docs() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((SELECT json_agg(json_build_object('id', d.id, 'title', d.title, 'content', left(d.content, 200),
                                                     'created_at', d.created_at) ORDER BY d.created_at DESC)
                     FROM public.policy_doc d), '[]'::json);
END $$;

CREATE OR REPLACE FUNCTION public.api_policy_doc_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_employee();
        t text := nullif(btrim(coalesce(p_data->>'title', '')), ''); c text := nullif(btrim(coalesce(p_data->>'content', '')), '');
        did uuid;
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Title is required' USING ERRCODE = 'PT400'; END IF;
  IF c IS NULL THEN RAISE EXCEPTION 'Content is required' USING ERRCODE = 'PT400'; END IF;
  IF length(t) > 300 THEN RAISE EXCEPTION 'Title is too long (max 300 characters)' USING ERRCODE = 'PT400'; END IF;
  IF length(c) > 1000000 THEN RAISE EXCEPTION 'Document is too large (max 1 MB of text)' USING ERRCODE = 'PT400'; END IF;
  INSERT INTO public.policy_doc (title, content, created_by) VALUES (t, c, eid) RETURNING id INTO did;
  RETURN json_build_object('id', did, 'title', t);
END $$;

CREATE OR REPLACE FUNCTION public.api_policy_doc_search(p_q text) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE lk text := '%' || replace(replace(replace(coalesce(p_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
BEGIN
  PERFORM crm_private.require_employee();
  RETURN coalesce((SELECT json_agg(json_build_object('id', d.id, 'title', d.title, 'content', left(d.content, 300),
                                                     'created_at', d.created_at) ORDER BY d.created_at DESC)
                     FROM public.policy_doc d WHERE d.title ILIKE lk OR d.content ILIKE lk), '[]'::json);
END $$;

-- ===========================================================================================
-- QUOTES
-- ===========================================================================================
ALTER TABLE public.outbox_message ADD COLUMN IF NOT EXISTS quote_data jsonb;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('quotes', 'quotes', false, 5242880, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 5242880, allowed_mime_types = ARRAY['application/pdf'];
DROP POLICY IF EXISTS crm_quotes_staff_read ON storage.objects;
CREATE POLICY crm_quotes_staff_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'quotes' AND (SELECT crm_private.is_sales_or_admin()));

-- Price maths (port of quote_generator.py): returns everything the PDF shows.
CREATE OR REPLACE FUNCTION crm_private.quote_figures(p_course_id uuid, p_discount numeric, p_installments int, p_down int)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE c record; disc_amt int; discounted int; total int; items jsonb; remaining int; per int; rem int; inst jsonb;
BEGIN
  SELECT co.id, co.name, co.base_fee INTO c FROM public.course co WHERE co.id = p_course_id AND co.active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No fee configured for this course. Add it in Course Config before generating a quote.' USING ERRCODE = 'PT400';
  END IF;
  disc_amt := trunc(c.base_fee * p_discount / 100)::int;
  discounted := c.base_fee - disc_amt;
  SELECT coalesce(jsonb_agg(jsonb_build_object('description', li.description, 'amount', li.amount) ORDER BY li.display_order), '[]'::jsonb),
         coalesce(sum(li.amount), 0)
    INTO items, total FROM public.course_line_item li WHERE li.course_id = c.id AND li.amount > 0;
  total := discounted + total;
  IF p_down > total THEN RAISE EXCEPTION 'Down payment cannot be more than the total fee' USING ERRCODE = 'PT400'; END IF;
  IF p_installments = 1 THEN
    inst := jsonb_build_array(jsonb_build_object('number', 1, 'amount', total, 'due', 'Full payment'));
  ELSE
    remaining := total - p_down; per := remaining / (p_installments - 1); rem := remaining % (p_installments - 1);
    inst := jsonb_build_array(jsonb_build_object('number', 1, 'amount', p_down, 'due', 'Down payment at enrollment'));
    FOR i IN 0 .. p_installments - 2 LOOP
      inst := inst || jsonb_build_object('number', i + 2, 'amount', per + CASE WHEN i < rem THEN 1 ELSE 0 END,
                                         'due', 'Month ' || ((i + 1) * 3));
    END LOOP;
  END IF;
  RETURN jsonb_build_object('course_id', c.id, 'course_name', c.name, 'base_fee', c.base_fee,
    'discount_percent', p_discount, 'discount_amount', disc_amt, 'discounted_base', discounted,
    'line_items', items, 'total', total, 'installment_count', p_installments, 'down_payment', p_down,
    'installments', inst);
END $$;

-- POST /api/quotes/generate (Sales/Admin): records the quote; the Edge Function then builds the PDF.
CREATE OR REPLACE FUNCTION public.api_quote_create(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.require_sales_or_admin('Quotes require Admin or Sales department');
        lid uuid := crm_private.to_uuid(p_data->>'lead_id', 'lead_id'); cid uuid := crm_private.to_uuid(p_data->>'course_id', 'course_id');
        disc numeric := coalesce(crm_private.to_num(p_data->>'discount_percent', 'Discount'), 0);
        n int := coalesce(crm_private.to_num(p_data->>'installment_count', 'Installments')::int, 1);
        down int := coalesce(crm_private.to_num(p_data->>'down_payment', 'Down payment')::int, 0);
        lead_name text; fig jsonb; qid text := upper(left(replace(gen_random_uuid()::text, '-', ''), 8)); oid uuid;
BEGIN
  IF cid IS NULL THEN RAISE EXCEPTION 'Select a course first' USING ERRCODE = 'PT400'; END IF;
  IF disc < 0 OR disc > 100 THEN RAISE EXCEPTION 'Discount must be between 0 and 100%%' USING ERRCODE = 'PT400'; END IF;
  IF n < 1 OR n > 24 THEN RAISE EXCEPTION 'Installments must be between 1 and 24' USING ERRCODE = 'PT400'; END IF;
  IF down < 0 THEN RAISE EXCEPTION 'Down payment cannot be negative' USING ERRCODE = 'PT400'; END IF;
  SELECT l.name INTO lead_name FROM public.lead l WHERE l.id = lid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found' USING ERRCODE = 'PT404'; END IF;
  fig := crm_private.quote_figures(cid, disc, n, CASE WHEN n = 1 THEN 0 ELSE down END);
  fig := fig || jsonb_build_object('quote_id', qid, 'lead_name', lead_name,
                                   'date', to_char(crm_private.today_ist(), 'FMDD FMMonth YYYY'));
  INSERT INTO public.outbox_message (lead_id, type, body, status, quote_data)
  VALUES (lid, 'quote', 'Quote for ' || (fig->>'course_name'), 'pending', fig)
  RETURNING id INTO oid;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (eid, 'generate_quote', 'quote', jsonb_build_object('lead_id', lid, 'course_id', cid, 'quote_id', qid, 'outbox_id', oid));
  RETURN json_build_object('id', oid, 'quote_id', qid, 'quote', fig);
END $$;

-- Storage path of a quote's PDF (Sales/Admin)
CREATE OR REPLACE FUNCTION public.api_quote_pdf_path(p_id uuid) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pth text;
BEGIN
  PERFORM crm_private.require_sales_or_admin('Quotes require Admin or Sales department');
  SELECT o.pdf_path INTO pth FROM public.outbox_message o WHERE o.id = p_id AND o.type = 'quote';
  IF pth IS NULL THEN RAISE EXCEPTION 'PDF not found' USING ERRCODE = 'PT404'; END IF;
  RETURN json_build_object('path', pth);
END $$;

-- The Edge Function stores the PDF path (or removes a quote whose PDF could not be built).
CREATE OR REPLACE FUNCTION public.svc_quote_set_pdf(p_id uuid, p_path text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.outbox_message SET pdf_path = p_path WHERE id = p_id AND type = 'quote'
$$;
CREATE OR REPLACE FUNCTION public.svc_quote_discard(p_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM public.outbox_message WHERE id = p_id AND type = 'quote' AND pdf_path IS NULL
$$;

-- Outbox list now also returns pdf_path (the screen shows the PDF link only when a PDF exists).
CREATE OR REPLACE FUNCTION public.api_outbox() RETURNS json
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.require_sales_or_admin('Outbox access requires Admin or Sales department');
  RETURN coalesce((
    SELECT json_agg(json_build_object('id', o.id, 'lead_id', o.lead_id, 'type', o.type, 'body', o.body,
             'status', o.status, 'created_at', o.created_at, 'lead_name', l.name, 'lead_phone', l.phone,
             'pdf_url', CASE WHEN o.type = 'quote' THEN '/api/quotes/' || o.id || '/pdf' END,
             'pdf_path', o.pdf_path)
           ORDER BY o.created_at DESC)
    FROM public.outbox_message o JOIN public.lead l ON l.id = o.lead_id
    WHERE o.status::text IN ('draft', 'pending', 'approved')
  ), '[]'::json);
END $$;

-- ===========================================================================================
-- WEBSITE LEAD INTAKE
-- ===========================================================================================
-- validate_charter: same checks as before; the error now also carries every field error (in the
-- website's order) in DETAIL so the intake can answer {"errors": {...}} like the Render API did.
CREATE OR REPLACE FUNCTION crm_private.validate_charter(d jsonb, require_date boolean) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE errs text[] := '{}'; name text; raw_phone text; digits text; origin text; dest text;
        dep text; pax_raw jsonb; pax int; email text; details jsonb; k text; lim int; v text;
        opt jsonb := '{"departureTime":5,"tripType":20,"returnDate":10,"aircraftPreference":40,"purpose":40,"additionalRequirements":2000,"sourcePath":200}';
BEGIN
  name := crm_private.charter_text(d->'name', 120);
  IF name IS NULL THEN errs := errs || 'name: Required'::text; END IF;
  raw_phone := coalesce(crm_private.charter_text(d->'phone', 30), '');
  digits := regexp_replace(raw_phone, '\D', '', 'g');
  IF length(digits) NOT BETWEEN 7 AND 15 THEN errs := errs || 'phone: Enter a valid phone number'::text; END IF;
  origin := crm_private.charter_text(d->'from', 200);
  dest := crm_private.charter_text(d->'to', 200);
  IF origin IS NULL THEN errs := errs || 'from: Required'::text; END IF;
  IF dest IS NULL THEN errs := errs || 'to: Required'::text; END IF;
  dep := crm_private.charter_text(d->'departureDate', 10);
  IF dep IS NOT NULL AND NOT crm_private.valid_iso_date(dep) THEN errs := errs || 'departureDate: Use YYYY-MM-DD'::text;
  ELSIF require_date AND dep IS NULL THEN errs := errs || 'departureDate: Required'::text; END IF;
  pax_raw := d->'passengers';
  IF pax_raw IS NULL OR jsonb_typeof(pax_raw) = 'null' OR (pax_raw #>> '{}') = '' THEN pax := NULL;
  ELSE
    BEGIN pax := (pax_raw #>> '{}')::numeric::int; EXCEPTION WHEN others THEN pax := -1; END;
  END IF;
  IF pax IS NOT NULL AND pax NOT BETWEEN 1 AND 500 THEN errs := errs || 'passengers: Between 1 and 500'::text; END IF;
  IF require_date AND pax IS NULL THEN errs := errs || 'passengers: Required'::text; END IF;
  email := crm_private.charter_text(d->'email', 200);
  IF email IS NOT NULL AND position('@' IN email) = 0 THEN errs := errs || 'email: Enter a valid email'::text; END IF;

  details := jsonb_build_object('from', origin, 'to', dest, 'departureDate', dep, 'passengers', pax);
  FOR k, lim IN SELECT key, value::int FROM jsonb_each_text(opt) LOOP
    v := crm_private.charter_text(d->k, lim);
    IF v IS NOT NULL THEN details := details || jsonb_build_object(k, v); END IF;
  END LOOP;
  IF details ? 'departureTime' AND (details->>'departureTime') !~ '^([01]\d|2[0-3]):[0-5]\d$' THEN
    errs := errs || 'departureTime: Use HH:MM'::text; END IF;
  IF details ? 'returnDate' AND NOT crm_private.valid_iso_date(details->>'returnDate') THEN
    errs := errs || 'returnDate: Use YYYY-MM-DD'::text; END IF;
  IF jsonb_typeof(d->'flexibleDates') = 'boolean' THEN details := details || jsonb_build_object('flexibleDates', d->'flexibleDates'); END IF;

  IF cardinality(errs) > 0 THEN
    RAISE EXCEPTION '%', errs[1] USING ERRCODE = 'PT400',  -- first error, same order as the Python version
      DETAIL = (SELECT json_object(array_agg(split_part(e, ': ', 1) ORDER BY o), array_agg(split_part(e, ': ', 2) ORDER BY o))::text
                  FROM unnest(errs) WITH ORDINALITY AS u(e, o));
  END IF;
  RETURN jsonb_build_object('name', name, 'phone', crm_private.norm_phone(raw_phone), 'email', email,
                            'details', jsonb_strip_nulls(details));
END $$;

-- Aviation enquiries from the institute websites (public form; port of lead_ingestion.py).
CREATE OR REPLACE FUNCTION crm_private.ingest_website_lead(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE raw_phone text := left(btrim(coalesce(p->>'phone', '')), 30); key text; ex uuid; lid uuid;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RETURN jsonb_build_object('error', 'Expected a JSON object'); END IF;
  IF length(regexp_replace(raw_phone, '\D', '', 'g')) NOT BETWEEN 7 AND 15 THEN
    RETURN jsonb_build_object('error', 'A valid phone number is required');
  END IF;
  key := crm_private.norm_phone(raw_phone);
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));      -- two identical submits at once -> one lead
  SELECT l.id INTO ex FROM public.lead l WHERE l.dedup_key = key;
  IF FOUND THEN RETURN jsonb_build_object('status', 'duplicate', 'lead_id', ex); END IF;
  INSERT INTO public.lead (name, phone, email, address, course_interest, utm_source, utm_medium, utm_campaign, status, dedup_key)
  VALUES (left(btrim(p->>'name'), 120), raw_phone, left(btrim(p->>'email'), 200), left(btrim(p->>'address'), 500),
          left(btrim(p->>'course_interest'), 120), left(btrim(p->>'utm_source'), 200), left(btrim(p->>'utm_medium'), 200),
          left(btrim(p->>'utm_campaign'), 200), 'new', key)
  RETURNING id INTO lid;
  INSERT INTO public.audit_log (action, entity, payload)
  VALUES ('create', 'lead', jsonb_build_object('lead_id', lid, 'source', 'website'));
  RETURN jsonb_build_object('status', 'created', 'lead_id', lid);
END $$;

-- Charter enquiries from bookmycharter.in (server-to-server; port of charter_ingestion.py).
CREATE OR REPLACE FUNCTION crm_private.ingest_charter_lead(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c jsonb; key text; ex record; lid uuid; det text;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('errors_json', '{"body": "Expected a JSON object"}');
  END IF;
  BEGIN
    c := crm_private.validate_charter(p, true);
  EXCEPTION WHEN SQLSTATE 'PT400' THEN
    GET STACKED DIAGNOSTICS det = PG_EXCEPTION_DETAIL;
    RETURN jsonb_build_object('errors_json', det);   -- kept as text so the field order survives
  END;
  key := 'charter:' || (c->>'phone') || ':' || lower(coalesce(btrim(c->'details'->>'from'), '')) || '|'
         || lower(coalesce(btrim(c->'details'->>'to'), '')) || '|' || lower(coalesce(btrim(c->'details'->>'departureDate'), ''));
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));
  SELECT l.id, l.name INTO ex FROM public.lead l WHERE l.dedup_key = key;
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate', 'lead_id', ex.id, 'name', ex.name, 'reference', crm_private.charter_reference(ex.id));
  END IF;
  INSERT INTO public.lead (name, phone, email, course_interest, utm_source, utm_medium, utm_campaign, status, dedup_key, segment, charter_details)
  VALUES (c->>'name', c->>'phone', c->>'email', 'Charter', 'Book My Charter website', 'website', c->'details'->>'sourcePath',
          'new', key, 'charter', c->'details')
  RETURNING id INTO lid;
  INSERT INTO public.audit_log (actor, action, entity, payload)
  VALUES (NULL, 'create', 'lead', jsonb_build_object('lead_id', lid, 'segment', 'charter', 'source', 'Book My Charter website'));
  RETURN jsonb_build_object('status', 'created', 'lead_id', lid, 'reference', crm_private.charter_reference(lid));
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_charter_ingest_token') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'crm_charter_ingest_token',
                                'Token for bookmycharter.in sending charter enquiries (crm-leads Edge Function)');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ingest_website_lead(payload jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.ingest_website_lead(payload) $$;
CREATE OR REPLACE FUNCTION public.svc_ingest_charter_lead(payload jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.ingest_charter_lead(payload) $$;
CREATE OR REPLACE FUNCTION public.svc_charter_token_ok(token text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.token_ok('crm_charter_ingest_token', token) $$;

-- ===========================================================================================
-- Permissions
-- ===========================================================================================
REVOKE ALL ON FUNCTION crm_private.quote_figures(uuid, numeric, int, int), crm_private.ingest_website_lead(jsonb),
  crm_private.ingest_charter_lead(jsonb) FROM PUBLIC, anon, authenticated;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['svc_quote_set_pdf(uuid, text)', 'svc_quote_discard(uuid)', 'svc_ingest_website_lead(jsonb)',
    'svc_ingest_charter_lead(jsonb)', 'svc_charter_token_ok(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['api_policy_docs()', 'api_policy_doc_create(jsonb)', 'api_policy_doc_search(text)',
    'api_quote_create(jsonb)', 'api_quote_pdf_path(uuid)', 'api_outbox()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- Admin may remove a quote PDF (e.g. a quote made by mistake).
DROP POLICY IF EXISTS crm_quotes_admin_delete ON storage.objects;
CREATE POLICY crm_quotes_admin_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'quotes' AND (SELECT crm_private.is_admin()));
