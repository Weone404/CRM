-- 067: FlightBridge "Write with AI" for outreach templates (engine 1.6.0).
--   * two more placeholders, filled per school when its draft is made, from verified data only:
--     {{state}} (state/province) and {{credential}} (the approval an official list shows, e.g. "FAA Part 141 certification").
--     fb_template_validate stays a COPY of flightbridge/outreach/templates.py validate().
--   * api_fb_template_generate_start: checks the admin, limits 40 generations a day per person, remembers the brief
--     (the person's own details and instructions) for next time; the Edge Function then asks the AI.
--   * api_fb_template_check_many: the same template checks for every AI version before it is shown.

CREATE OR REPLACE FUNCTION crm_private.fb_template_validate(p_subject text, p_body text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE subj text := crm_private.fb_strip(p_subject); body text := crm_private.fb_strip(p_body);
  errors text[] := '{}'; warnings text[] := '{}'; used text[]; nm text; stripped text; hits text[];
  allowed text[] := ARRAY['city', 'country', 'credential', 'school_name', 'state'];
  var_re text := '\{\{\s*([a-zA-Z_]+)\s*\}\}';
BEGIN
  IF subj = '' OR length(subj) > 150 THEN errors := errors || 'subject must be 1-150 characters'::text; END IF;
  IF length(body) < 20 THEN errors := errors || 'body is too short'::text; END IF;
  IF subj ~* '^\s*(re|fw|fwd)\s*:' THEN
    errors := errors || 'subject must not start with Re:/Fwd: (it would look like a reply)'::text;
  END IF;
  SELECT coalesce(array_agg(x ORDER BY x COLLATE "C"), '{}') INTO used
    FROM (SELECT DISTINCT m[1] AS x FROM regexp_matches(subj || body, var_re, 'g') m) s;
  FOREACH nm IN ARRAY used LOOP
    IF NOT nm = ANY (allowed) THEN
      errors := errors || format('unknown placeholder {{%s}} (allowed: {{city}}, {{country}}, {{credential}}, {{school_name}}, {{state}})', nm);
    END IF;
  END LOOP;
  stripped := regexp_replace(subj || E'\n' || body, var_re, 'X', 'g');
  IF stripped ~* '\{\{|\}\}|\[\[|\]\]|PLACEHOLDER|\yTODO\y|lorem ipsum|<insert' THEN
    errors := errors || 'contains an unresolved placeholder or TODO'::text;
  END IF;
  SELECT array_agg(DISTINCT tag COLLATE "C" ORDER BY tag COLLATE "C") INTO hits FROM (VALUES
    ('\y\d[\d,]*\s*\+?\s*(pilots|students|candidates|graduates)\y', 'unverified_volume_claim'),
    ('100\s*%\s*placement', 'unverified_placement_claim'),
    ('\yplacement (guarantee|assured|assistance)\y', 'unverified_placement_claim'),
    ('(?n)\yguarantee(d)?\y.*\y(job|placement|licen[cs]e|pass)\y', 'guarantee_claim'),
    ('\your (flying school|aircraft|fleet)\y', 'operates_aircraft_claim'),
    ('\yDGCA[- ]approved\y', 'unverified_regulatory_claim'),
    ('\y(approved|certified|registered) (FTO|flying training organi[sz]ation|ATO)\y', 'unverified_regulatory_claim'),
    ('\ysince 2011\y', 'contradicted_founding_year'),
    ('\y(airline partners?|partner airlines?)\y', 'unverified_partner_claim'),
    ('\y(india''?s )?(most trusted|best|no\.? ?1|#1|premier|leading)\y', 'superlative_claim'),
    ('flystar|flying star', 'other_brand')) b(pat, tag)
   WHERE stripped ~* pat;
  IF hits IS NOT NULL THEN
    errors := errors || ('contains claims that are not approved: ' || array_to_string(hits, ', '));
  END IF;
  IF body ~* '(?n)(unsubscribe|^\s*--\s*$|\yRef:\s*FB-)' THEN
    warnings := warnings || 'do not add an unsubscribe line, signature divider or Ref: — the system appends the legal footer'::text;
  END IF;
  RETURN jsonb_build_object('ok', cardinality(errors) = 0, 'errors', to_jsonb(errors), 'warnings', to_jsonb(warnings),
    'placeholders', to_jsonb(ARRAY(SELECT u FROM unnest(used) u WHERE u = ANY (allowed) ORDER BY u COLLATE "C")));
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_template_brief() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_admin();
  RETURN (SELECT value::json FROM flightbridge.system_setting WHERE key = 'template_brief');
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_template_generate_start(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); b jsonb; n int; used int;
BEGIN
  b := jsonb_build_object(
    'sender_name', crm_private.fb_text(p_data, 'sender_name', 120),
    'sender_title', crm_private.fb_text(p_data, 'sender_title', 120),
    'organisation', coalesce(nullif(crm_private.fb_text(p_data, 'organisation', 160), ''), 'We One Aviation'),
    'sender_email', crm_private.fb_text(p_data, 'sender_email', 160),
    'sender_phone', crm_private.fb_text(p_data, 'sender_phone', 60),
    'about', crm_private.fb_text(p_data, 'about', 2000),
    'reason', crm_private.fb_text(p_data, 'reason', 1500),
    'value', crm_private.fb_text(p_data, 'value', 1500),
    'next_step', crm_private.fb_text(p_data, 'next_step', 300),
    'instructions', crm_private.fb_text(p_data, 'instructions', 3000));
  IF length(coalesce(b->>'reason', '') || coalesce(b->>'instructions', '')) < 10 THEN
    RAISE EXCEPTION 'Describe the email you want (why you are writing, or your instructions)' USING ERRCODE = 'PT400';
  END IF;
  n := least(5, greatest(3, CASE WHEN p_data->>'count' ~ '^[0-9]{1,2}$' THEN (p_data->>'count')::int ELSE 3 END));
  SELECT count(*) INTO used FROM flightbridge.audit_log
   WHERE action = 'template_generated' AND actor_id::text = eid::text AND at > now() - interval '1 day';
  IF used >= 40 THEN
    RAISE EXCEPTION 'Daily limit reached (40 generations). Try again tomorrow.' USING ERRCODE = 'PT429';
  END IF;
  INSERT INTO flightbridge.system_setting (key, value, updated_at) VALUES ('template_brief', b, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM crm_private.fb_audit(eid, 'template_generated', 'outreach_template', 'ai', jsonb_build_object('count', n));
  RETURN (b || jsonb_build_object('count', n))::json;
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_template_check_many(p_items jsonb) RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.fb_admin();
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 60 THEN
    RAISE EXCEPTION 'items must be a list of at most 60' USING ERRCODE = 'PT400';
  END IF;
  RETURN coalesce((SELECT json_agg(crm_private.fb_template_validate(left(x->>'subject', 150), left(x->>'body', 20000)) ORDER BY o)
                     FROM jsonb_array_elements(p_items) WITH ORDINALITY t(x, o)), '[]');
END $$;

REVOKE ALL ON FUNCTION public.api_fb_template_brief() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_fb_template_generate_start(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_fb_template_check_many(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_template_brief() TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_template_generate_start(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.api_fb_template_check_many(jsonb) TO authenticated;
