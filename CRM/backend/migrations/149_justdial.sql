-- 149: JustDial leads straight into Leads. JustDial has no self-serve setup: each listing (We One Aviation, Flying Star, ...)
-- gets a secret CRM link, the JustDial account manager adds it, and JustDial then calls it for every enquiry
-- (crm-leads Edge Function: GET or POST /crm-leads/justdial/<secret>, answers "RECEIVED").
-- Each enquiry becomes a lead (source "JustDial", the listing as medium, the JustDial category as campaign) with a
-- "call now" follow-up in Today. JustDial retries, so the same JustDial lead id is stored once; a number already in
-- Leads is not created twice. Every call is logged for the JustDial card on the Leads page. Undo: 149_justdial_down.sql.

CREATE TABLE IF NOT EXISTS public.jd_listing (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  segment text NOT NULL DEFAULT 'aviation' CHECK (segment IN ('aviation', 'charter')),
  token text NOT NULL UNIQUE DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  assign_to uuid REFERENCES public.employee(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.jd_hit (
  id bigserial PRIMARY KEY,
  listing_id uuid NOT NULL REFERENCES public.jd_listing(id) ON DELETE CASCADE,
  jd_leadid text, status text NOT NULL CHECK (status IN ('created', 'repeat', 'duplicate', 'rejected', 'test')),
  lead_id uuid REFERENCES public.lead(id) ON DELETE SET NULL,
  name text, phone text, category text, place text, detail text,
  payload jsonb NOT NULL DEFAULT '{}', at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS uq_jd_hit_leadid ON public.jd_hit (listing_id, jd_leadid) WHERE jd_leadid IS NOT NULL AND status IN ('created', 'repeat');
CREATE INDEX IF NOT EXISTS idx_jd_hit_listing_at ON public.jd_hit (listing_id, at DESC);
ALTER TABLE public.jd_listing ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jd_hit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.jd_listing, public.jd_hit FROM anon, authenticated;

INSERT INTO public.jd_listing (name, segment)
SELECT v.n, 'aviation' FROM (VALUES ('We One Aviation'), ('Flying Star')) v(n)
WHERE NOT EXISTS (SELECT 1 FROM public.jd_listing);

-- One JustDial call. p: the fields JustDial sends (any case): leadid, leadtype, prefix, name, mobile, phone, email, date, time,
-- category, city, area, brancharea, pincode, branchpin, company, dncmobile, dncphone, parentid.
CREATE OR REPLACE FUNCTION crm_private.jd_ingest(p_token text, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l public.jd_listing; d jsonb; v_lead text; nm text; ph text; em text; cat text; place text; key text; ex uuid; lid uuid; who uuid;
  st text; det text;
BEGIN
  SELECT * INTO l FROM public.jd_listing WHERE token = p_token AND active;
  IF l.id IS NULL THEN RETURN jsonb_build_object('error', 'unknown'); END IF;
  SELECT coalesce(jsonb_object_agg(lower(k), CASE WHEN jsonb_typeof(v) = 'string' THEN to_jsonb(left(btrim(v #>> '{}'), 500)) ELSE v END), '{}')
    INTO d FROM jsonb_each(CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}' END) e(k, v);
  v_lead := nullif(left(d->>'leadid', 80), '');
  nm := nullif(btrim(concat_ws(' ', nullif(d->>'prefix', ''), nullif(d->>'name', ''))), '');
  ph := coalesce(nullif(regexp_replace(coalesce(d->>'mobile', ''), '[^\d+]', '', 'g'), ''), nullif(regexp_replace(coalesce(d->>'phone', ''), '[^\d+]', '', 'g'), ''));
  em := nullif(lower(d->>'email'), '');
  IF em IS NOT NULL AND em !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' THEN em := NULL; END IF;
  cat := nullif(d->>'category', '');
  place := nullif(concat_ws(', ', nullif(coalesce(nullif(d->>'area', ''), d->>'brancharea'), ''), nullif(d->>'city', ''), nullif(d->>'pincode', '')), '');

  -- a test from the JustDial card: logged, no lead
  IF v_lead ILIKE 'TEST%' THEN
    INSERT INTO public.jd_hit (listing_id, jd_leadid, status, name, phone, category, place, payload, detail)
    VALUES (l.id, NULL, 'test', nm, ph, cat, place, d, 'Test from the CRM');
    RETURN jsonb_build_object('status', 'test');
  END IF;
  -- JustDial retries: the same JustDial lead is handled once
  IF v_lead IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('jd|' || l.id || '|' || v_lead));
    SELECT h.lead_id INTO ex FROM public.jd_hit h WHERE h.listing_id = l.id AND h.jd_leadid = v_lead AND h.status IN ('created', 'repeat');
    IF FOUND THEN
      INSERT INTO public.jd_hit (listing_id, status, lead_id, name, phone, category, place, payload, detail)
      VALUES (l.id, 'duplicate', ex, nm, ph, cat, place, d, 'JustDial sent this enquiry again');
      RETURN jsonb_build_object('status', 'duplicate', 'lead_id', ex);
    END IF;
  END IF;
  IF length(regexp_replace(coalesce(ph, ''), '\D', '', 'g')) NOT BETWEEN 7 AND 15 THEN
    INSERT INTO public.jd_hit (listing_id, jd_leadid, status, name, phone, category, place, payload, detail)
    VALUES (l.id, NULL, 'rejected', nm, ph, cat, place, d, 'No phone number in the enquiry');
    RETURN jsonb_build_object('status', 'rejected');
  END IF;

  key := crm_private.norm_phone(ph);
  PERFORM pg_advisory_xact_lock(hashtext('lead|' || key));
  SELECT x.id INTO ex FROM public.lead x WHERE x.dedup_key = key;
  IF FOUND THEN
    -- already in Leads: keep the person once, note the new JustDial enquiry on the lead and ask for a call back
    UPDATE public.lead SET last_note = left(format('JustDial again%s%s', coalesce(' · ' || cat, ''), coalesce(' · ' || place, '')), 500) WHERE id = ex;
    lid := ex; st := 'repeat'; det := 'Already in Leads; a call is added to Today';
  ELSE
    INSERT INTO public.lead (name, phone, email, address, utm_source, utm_medium, utm_campaign, status, dedup_key, segment, assigned_to, last_note)
    VALUES (coalesce(left(nm, 120), 'JustDial enquiry'), left(ph, 30), left(em, 200), left(place, 500), 'JustDial', l.name, left(cat, 200), 'new', key,
            l.segment, l.assign_to, left(format('JustDial%s%s%s', coalesce(' · ' || cat, ''), coalesce(' · ' || place, ''),
                                               coalesce(' · ' || nullif(d->>'leadtype', ''), '')), 500))
    RETURNING id INTO lid;
    st := 'created'; det := NULL;
    IF to_regclass('public.audit_log') IS NOT NULL THEN
      INSERT INTO public.audit_log (action, entity, payload) VALUES ('create', 'lead', jsonb_build_object('lead_id', lid, 'source', 'justdial', 'listing', l.name));
    END IF;
  END IF;
  -- "call now" in Today (one open call per lead)
  who := coalesce(l.assign_to, (SELECT e.id FROM public.employee e WHERE e.active AND e.department::text = 'Admin' ORDER BY e.created_at LIMIT 1));
  IF who IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.followup f WHERE f.lead_id = lid AND NOT coalesce(f.done, false)) THEN
    INSERT INTO public.followup (lead_id, due_date, reason, created_by, has_time)
    VALUES (lid, now(), left(format('New JustDial enquiry%s — call now', coalesce(': ' || cat, '')), 200), who, true);
  END IF;
  INSERT INTO public.jd_hit (listing_id, jd_leadid, status, lead_id, name, phone, category, place, payload, detail)
  VALUES (l.id, v_lead, st, lid, nm, ph, cat, place, d, det);
  DELETE FROM public.jd_hit WHERE at < now() - interval '400 days';
  RETURN jsonb_build_object('status', st, 'lead_id', lid);
END $$;

CREATE OR REPLACE FUNCTION public.svc_jd_ingest(p_token text, p_data jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT crm_private.jd_ingest(p_token, p_data) $$;

-- The JustDial card: every listing with its numbers and latest enquiries. Links and settings for Admin only.
CREATE OR REPLACE FUNCTION public.api_jd_listings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE adm boolean := crm_private.is_admin();
BEGIN
  PERFORM crm_private.require_sales_or_admin('You do not have access to Leads');
  RETURN jsonb_build_object('is_admin', adm,
    'listings', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', l.id, 'name', l.name, 'segment', l.segment, 'active', l.active,
        'assign_to', l.assign_to, 'assign_name', (SELECT e.name FROM public.employee e WHERE e.id = l.assign_to),
        'token', CASE WHEN adm THEN l.token END,
        'leads_30', (SELECT count(*) FROM public.jd_hit h WHERE h.listing_id = l.id AND h.status = 'created' AND h.at > now() - interval '30 days'),
        'repeats_30', (SELECT count(*) FROM public.jd_hit h WHERE h.listing_id = l.id AND h.status = 'repeat' AND h.at > now() - interval '30 days'),
        'leads_total', (SELECT count(*) FROM public.jd_hit h WHERE h.listing_id = l.id AND h.status = 'created'),
        'last_lead_at', (SELECT max(h.at) FROM public.jd_hit h WHERE h.listing_id = l.id AND h.status IN ('created', 'repeat')),
        'last_call_at', (SELECT max(h.at) FROM public.jd_hit h WHERE h.listing_id = l.id),
        'tested_at', (SELECT max(h.at) FROM public.jd_hit h WHERE h.listing_id = l.id AND h.status = 'test'),
        'recent', (SELECT coalesce(jsonb_agg(x ORDER BY x.at DESC), '[]') FROM (
                     SELECT h.at, h.status, h.lead_id, h.name, h.category, h.place, h.detail FROM public.jd_hit h
                      WHERE h.listing_id = l.id AND h.status <> 'test' ORDER BY h.at DESC LIMIT 6) x))
      ORDER BY l.created_at) FROM public.jd_listing l), '[]'),
    'people', CASE WHEN adm THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) ORDER BY e.name), '[]')
                                   FROM public.employee e WHERE e.active AND e.department::text IN ('Admin', 'Sales')) END);
END $$;

-- Add (p_id NULL) or change a listing. Admin only.
CREATE OR REPLACE FUNCTION public.api_jd_listing_save(p_id uuid, p_name text, p_segment text DEFAULT 'aviation', p_assign_to uuid DEFAULT NULL, p_active boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nm text := btrim(coalesce(p_name, '')); v uuid := p_id;
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change JustDial settings' USING ERRCODE = 'PT403'; END IF;
  IF nm = '' OR char_length(nm) > 60 THEN RAISE EXCEPTION 'Give the listing a short name' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p_segment, '') NOT IN ('aviation', 'charter') THEN RAISE EXCEPTION 'Leads go to Aviation or Charter' USING ERRCODE = 'PT422'; END IF;
  IF p_assign_to IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.employee e WHERE e.id = p_assign_to AND e.active) THEN
    RAISE EXCEPTION 'That team member is not active' USING ERRCODE = 'PT422'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.jd_listing (name, segment, assign_to, active) VALUES (nm, p_segment, p_assign_to, coalesce(p_active, true)) RETURNING id INTO v;
  ELSE
    UPDATE public.jd_listing SET name = nm, segment = p_segment, assign_to = p_assign_to, active = coalesce(p_active, true), updated_at = now() WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'This listing is not in the CRM any more' USING ERRCODE = 'PT404'; END IF;
  END IF;
  RETURN jsonb_build_object('id', v);
END $$;

-- A new secret link (the old one stops working at once; send the new one to JustDial).
CREATE OR REPLACE FUNCTION public.api_jd_listing_new_link(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change JustDial settings' USING ERRCODE = 'PT403'; END IF;
  UPDATE public.jd_listing SET token = t, updated_at = now() WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'This listing is not in the CRM any more' USING ERRCODE = 'PT404'; END IF;
  RETURN jsonb_build_object('token', t);
END $$;

CREATE OR REPLACE FUNCTION public.api_jd_listing_remove(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin can change JustDial settings' USING ERRCODE = 'PT403'; END IF;
  DELETE FROM public.jd_listing WHERE id = p_id;   -- its leads stay in Leads
  RETURN jsonb_build_object('removed', FOUND);
END $$;

REVOKE ALL ON FUNCTION crm_private.jd_ingest(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.svc_jd_ingest(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_jd_ingest(text, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.api_jd_listings(), public.api_jd_listing_save(uuid, text, text, uuid, boolean), public.api_jd_listing_new_link(uuid),
  public.api_jd_listing_remove(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_jd_listings(), public.api_jd_listing_save(uuid, text, text, uuid, boolean), public.api_jd_listing_new_link(uuid),
  public.api_jd_listing_remove(uuid) TO authenticated;
