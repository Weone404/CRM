-- 058: FlightBridge School Detector API, "Check needed" for countries without a register (mirrors engine 1.3.0
-- eligibility._no_rules and confirm()), and the world-sweep switch in Automation settings.

CREATE OR REPLACE FUNCTION crm_private.fb_evaluate_org(p_org uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o record; rule jsonb; reasons jsonb := '[]'; decision text; sig jsonb := '{}'; ev jsonb := '{}';
  prof record; pages bigint; closed boolean; r record; claims text[] := '{}'; c text; e jsonb;
BEGIN
  SELECT country, org_kind, eligibility, eligibility_reasons INTO o FROM flightbridge.organisation WHERE id = p_org;
  IF NOT FOUND THEN RETURN 'unknown'; END IF;
  IF o.org_kind = 'ground_school' THEN RETURN 'unknown'; END IF;
  IF o.eligibility = 'unqualified' AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(o.eligibility_reasons, '[]')) x
                                                WHERE x->>'code' = 'human_unqualified') THEN
    RETURN 'unqualified';
  END IF;
  rule := crm_private.fb_eligibility_rules() -> (o.country::text);
  SELECT signals, evidence INTO prof FROM flightbridge.organisation_profile WHERE org_id = p_org;
  SELECT count(*) INTO pages FROM flightbridge.website_page WHERE org_id = p_org AND http_status = 200;
  closed := EXISTS (SELECT 1 FROM flightbridge.audit_log WHERE entity = 'organisation' AND entity_id = p_org::text
                     AND action = 'place_closed' LIMIT 1);
  IF prof.signals IS NOT NULL AND jsonb_typeof(prof.signals) = 'object' THEN sig := prof.signals; END IF;
  IF jsonb_typeof(prof.evidence) = 'array' THEN
    FOR e IN SELECT value FROM jsonb_array_elements(prof.evidence) LOOP
      ev := ev || jsonb_build_object(e->>'signal', e);      -- later entries win, as in the dict comprehension
    END LOOP;
  END IF;

  IF rule IS NULL THEN
    -- No register for this country yet (owner's decision 2026-11-04): website read -> "Check needed" (eligible_claimed);
    -- a person's check on the national aviation authority's site (NATIONAL_APPROVAL) -> verified. Mirrors _no_rules().
    SELECT approval_ref, source_url INTO r FROM flightbridge.regulatory_approval
     WHERE org_id = p_org AND classification = 'NATIONAL_APPROVAL' AND status = 'verified_by_human' LIMIT 1;
    IF closed THEN
      decision := 'unqualified';
      reasons := '[{"code": "closed", "text": "Listed as permanently closed"}]';
    ELSIF FOUND THEN
      decision := 'eligible_verified';
      reasons := jsonb_build_array(jsonb_build_object('code', 'verified',
        'text', crm_private.fb_strip(format('Confirmed by a person on the aviation authority''s site %s', coalesce(r.approval_ref, ''))),
        'source_url', r.source_url));
    ELSIF crm_private.fb_truthy(sig->'helicopter') AND NOT crm_private.fb_truthy(sig->'aeroplane')
       AND NOT crm_private.fb_truthy(sig->'has_cpl') THEN
      decision := 'unqualified';
      reasons := '[{"code": "helicopter_only", "text": "Website mentions helicopters only (no aeroplane training)"}]';
    ELSIF crm_private.fb_truthy(sig->'drone') AND NOT crm_private.fb_truthy(sig->'aeroplane')
       AND NOT crm_private.fb_truthy(sig->'has_cpl') THEN
      decision := 'unqualified';
      reasons := '[{"code": "drone_only", "text": "Website is about drones, not pilot training"}]';
    ELSIF pages > 0 THEN
      decision := 'eligible_claimed';
      reasons := jsonb_build_array(jsonb_build_object('code', 'no_rules', 'text', format('No approval register for %s set up yet: '
        'check the school''s approval on the national aviation authority''s site', o.country)));
    ELSE
      decision := 'unknown';
      reasons := jsonb_build_array(jsonb_build_object('code', 'no_rules', 'text', format('No eligibility rules set for %s yet', o.country)));
    END IF;
  ELSIF closed THEN
    decision := 'unqualified';
    reasons := '[{"code": "closed", "text": "Listed as permanently closed"}]';
  ELSE
    FOR r IN SELECT classification, status, authority_code, approval_ref, source_url FROM flightbridge.regulatory_approval
              WHERE org_id = p_org LOOP
      IF rule->'verified' ? r.classification AND r.status IN ('listed_in_register', 'verified_by_human') THEN
        reasons := reasons || jsonb_build_array(jsonb_build_object('code', 'verified',
          'text', crm_private.fb_strip(format('%s: %s %s', CASE WHEN r.status = 'verified_by_human'
                   THEN 'Confirmed by a person on the regulator''s site' ELSE 'Listed in the official register' END,
                   r.authority_code, coalesce(r.approval_ref, ''))),
          'source_url', r.source_url));
      END IF;
    END LOOP;
    IF jsonb_array_length(reasons) > 0 THEN
      decision := 'eligible_verified';
    ELSE
      FOR c IN SELECT value FROM jsonb_array_elements_text(rule->'claims') LOOP
        IF crm_private.fb_truthy(sig->c) THEN claims := claims || c; END IF;
      END LOOP;
      IF crm_private.fb_truthy(sig->'helicopter') AND NOT crm_private.fb_truthy(sig->'aeroplane')
         AND NOT crm_private.fb_truthy(sig->'has_cpl') THEN
        decision := 'unqualified';
        reasons := '[{"code": "helicopter_only", "text": "Website mentions helicopters only (no aeroplane training)"}]';
      ELSIF crm_private.fb_truthy(sig->'drone') AND NOT crm_private.fb_truthy(sig->'aeroplane')
         AND NOT crm_private.fb_truthy(sig->'has_cpl') AND cardinality(claims) = 0 THEN
        decision := 'unqualified';
        reasons := '[{"code": "drone_only", "text": "Website is about drones, not pilot training"}]';
      ELSIF cardinality(claims) > 0 THEN
        decision := 'eligible_claimed';
        FOREACH c IN ARRAY claims LOOP
          reasons := reasons || jsonb_build_array(jsonb_build_object('code', 'claim:' || c, 'text', crm_private.fb_claim_text(c),
            'excerpt', coalesce(ev->c->'excerpt', 'null'), 'source_url', coalesce(ev->c->'url', 'null')));
        END LOOP;
      ELSIF pages > 0 THEN
        decision := 'unqualified';
        reasons := jsonb_build_array(jsonb_build_object('code', 'no_credential',
          'text', format('Website read (%s pages): no %s found', pages, rule->>'credential')));
      ELSE
        decision := 'unknown';
        reasons := '[{"code": "not_researched", "text": "Website not read yet"}]';
      END IF;
    END IF;
  END IF;

  UPDATE flightbridge.organisation SET eligibility = decision, eligibility_reasons = reasons, eligibility_checked_at = now()
   WHERE id = p_org;
  IF o.eligibility IS DISTINCT FROM decision THEN
    INSERT INTO flightbridge.audit_log (actor_type, actor_id, action, entity, entity_id, payload)
    VALUES ('system', NULL, 'eligibility_set', 'organisation', p_org::text,
            jsonb_build_object('from', o.eligibility, 'to', decision, 'reasons', reasons));
  END IF;
  RETURN decision;
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_eligibility(p_id text, p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_member();
  dec text := crm_private.fb_text(p_data, 'decision', NULL, true);
  ref text := crm_private.fb_text(p_data, 'reference', 80);
  src text := crm_private.fb_text(p_data, 'source_url', 2048);
  note text := crm_private.fb_text(p_data, 'note', 500);
  v_org uuid; ctry text; rule jsonb; result text;
BEGIN
  IF dec NOT IN ('confirm', 'unqualified', 'recheck') THEN
    RAISE EXCEPTION 'decision must be confirm, unqualified or recheck' USING ERRCODE = 'PT400';
  END IF;
  IF dec = 'unqualified' AND crm_private.fb_strip(note) = '' THEN
    RAISE EXCEPTION 'Say why it''s unqualified' USING ERRCODE = 'PT400';
  END IF;
  IF coalesce(src, '') <> '' AND NOT (lower(src) LIKE 'https://%' OR lower(src) LIKE 'http://%') THEN
    RAISE EXCEPTION 'source_url must be a web address' USING ERRCODE = 'PT400';
  END IF;
  v_org := crm_private.fb_uuid(p_id, 'School not found');
  SELECT country::text INTO ctry FROM flightbridge.organisation WHERE id = v_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'School not found' USING ERRCODE = 'PT404'; END IF;

  IF dec = 'confirm' THEN
    -- A person checked the regulator's site: record the country's main credential as verified_by_human.
    rule := crm_private.fb_eligibility_rules() -> ctry;
    IF rule IS NULL THEN          -- no register for this country: the person records the authority page they checked
      IF coalesce(src, '') = '' THEN
        RAISE EXCEPTION 'Paste the aviation authority page you checked' USING ERRCODE = 'PT400';
      END IF;
      rule := '{"confirm_as": {"authority": "NATIONAL_CAA", "classification": "NATIONAL_APPROVAL"}, "lookup": []}'::jsonb;
    END IF;
    INSERT INTO flightbridge.regulatory_approval (org_id, authority_code, classification, approval_ref, status,
                                                  source_url, checked_at, checked_by, next_check_due)
    VALUES (v_org, rule->'confirm_as'->>'authority', rule->'confirm_as'->>'classification', nullif(ref, ''), 'verified_by_human',
            coalesce(nullif(src, ''), rule->'lookup'->0->>1), now(), eid, now() + interval '90 days')
    ON CONFLICT (org_id, authority_code, classification) DO UPDATE
      SET status = 'verified_by_human', approval_ref = coalesce(EXCLUDED.approval_ref, flightbridge.regulatory_approval.approval_ref),
          source_url = EXCLUDED.source_url, checked_at = now(), checked_by = EXCLUDED.checked_by,
          next_check_due = EXCLUDED.next_check_due;
    UPDATE flightbridge.organisation SET eligibility_reasons = '[]'::jsonb WHERE id = v_org;   -- clears human_unqualified
    result := crm_private.fb_evaluate_org(v_org);
  ELSIF dec = 'unqualified' THEN
    UPDATE flightbridge.organisation SET eligibility = 'unqualified',
           eligibility_reasons = jsonb_build_array(jsonb_build_object('code', 'human_unqualified',
             'text', 'Marked unqualified by a person: ' || crm_private.fb_strip(note))),
           eligibility_checked_at = now() WHERE id = v_org;
    PERFORM crm_private.fb_audit(eid, 'eligibility_set', 'organisation', v_org::text,
      jsonb_build_object('to', 'unqualified', 'by', 'employee', 'note', crm_private.fb_strip(note)));
    result := 'unqualified';
  ELSE
    UPDATE flightbridge.organisation SET eligibility_reasons = '[]'::jsonb WHERE id = v_org;
    result := crm_private.fb_evaluate_org(v_org);
  END IF;
  PERFORM crm_private.fb_audit(eid, 'eligibility_' || dec, 'organisation', v_org::text,
    jsonb_build_object('result', result, 'reference', ref, 'note', note, 'by_role', crm_private.fb_role()));
  RETURN json_build_object('eligibility', result);
END $$;

CREATE OR REPLACE FUNCTION public.api_fb_autopilot_set(p_data jsonb) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE eid uuid := crm_private.fb_admin(); v json;
BEGIN
  v := json_build_object(
    'discover_areas', crm_private.fb_bool(p_data, 'discover_areas', true),
    'find_websites', crm_private.fb_bool(p_data, 'find_websites'),
    'research', crm_private.fb_bool(p_data, 'research'),
    'find_contacts', crm_private.fb_bool(p_data, 'find_contacts', true),
    'eligibility', crm_private.fb_bool(p_data, 'eligibility', true),
    'qualify', crm_private.fb_bool(p_data, 'qualify'),
    'draft', crm_private.fb_bool(p_data, 'draft'),
    'batch_size', crm_private.fb_int(p_data, 'batch_size', 1, 50, NULL, true),
    'areas_per_cycle', crm_private.fb_int(p_data, 'areas_per_cycle', 1, 10, 2),
    'world_sweep', crm_private.fb_bool(p_data, 'world_sweep', true));
  PERFORM crm_private.fb_set_setting('autopilot', v::jsonb, eid);
  PERFORM crm_private.fb_audit(eid, 'autopilot_set', 'system_setting', 'autopilot', v::jsonb);
  RETURN v;
END $$;

-- School Detector (FlightBridge AI): world-sweep progress, Google free-quota meter and recent finds for the live globe.
CREATE OR REPLACE FUNCTION public.api_fb_detector() RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg jsonb; caps jsonb := '{"text_search_pro": 4500, "text_search_enterprise": 900,
                                   "place_details_pro": 4500, "place_details_enterprise": 900}';
  k text; m date := date_trunc('month', now() AT TIME ZONE 'UTC')::date;
BEGIN
  PERFORM crm_private.fb_member();
  -- same rule as flightbridge.research.quota.caps(): an override may lower a cap, never raise it past Google's free tier
  SELECT value INTO cfg FROM flightbridge.system_setting WHERE key = 'google_budget';
  IF jsonb_typeof(cfg) = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(caps) LOOP
      IF jsonb_typeof(cfg->k) = 'number' AND (cfg->>k)::numeric = trunc((cfg->>k)::numeric)
         AND (cfg->>k)::numeric BETWEEN 0 AND (caps->>k)::numeric / 0.9 THEN
        caps := caps || jsonb_build_object(k, (cfg->>k)::int);
      END IF;
    END LOOP;
  END IF;
  RETURN json_build_object(
    'quota', json_build_object('month', m, 'skus', (
       SELECT json_object_agg(c.key, json_build_object('cap', c.value::int,
                'used', coalesce((SELECT calls FROM flightbridge.google_usage u WHERE u.month = m AND u.sku = c.key), 0)))
         FROM jsonb_each_text(caps) c)),
    'totals', (SELECT json_build_object(
        'countries', count(*), 'countries_done', count(*) FILTER (WHERE finished_at IS NOT NULL),
        'squares_total', coalesce(sum(cells_total), 0), 'squares_done', coalesce(sum(cells_done), 0),
        'schools_found', coalesce(sum(schools_found), 0), 'schools_new', coalesce(sum(schools_new), 0),
        'all_schools', (SELECT count(*) FROM flightbridge.organisation WHERE deleted_at IS NULL),
        'detections_24h', (SELECT count(*) FROM flightbridge.detection WHERE at > now() - interval '24 hours'),
        'new_24h', (SELECT count(*) FROM flightbridge.detection WHERE is_new AND at > now() - interval '24 hours'))
        FROM flightbridge.sweep_country),
    'countries', coalesce((SELECT json_agg(json_build_object('country', country, 'priority', priority, 'pass', pass,
        'squares_total', cells_total, 'squares_done', cells_done, 'schools_found', schools_found, 'schools_new', schools_new,
        'started_at', started_at, 'finished_at', finished_at, 'enabled', enabled,
        'state', CASE WHEN finished_at IS NOT NULL THEN 'done' WHEN started_at IS NOT NULL THEN 'scanning' ELSE 'queued' END)
        ORDER BY priority) FROM flightbridge.sweep_country), '[]'),
    'scanning', (SELECT json_build_object('country', country, 'lat0', lat0, 'lng0', lng0, 'lat1', lat1, 'lng1', lng1,
                   'depth', depth, 'at', searched_at, 'status', status)
                   FROM flightbridge.sweep_cell WHERE searched_at IS NOT NULL ORDER BY searched_at DESC LIMIT 1),
    'recent', coalesce((SELECT json_agg(x ORDER BY x.at DESC) FROM (
        SELECT d.org_id, d.name, d.country, round(d.lat::numeric, 3) AS lat, round(d.lng::numeric, 3) AS lng, d.is_new, d.at,
               o.eligibility
          FROM flightbridge.detection d JOIN flightbridge.organisation o ON o.id = d.org_id
         ORDER BY d.at DESC LIMIT 60) x), '[]'),
    -- one dot per school for the globe: [lat, lng, e] with e = 2 eligible, 1 check needed, 0 other
    'points', coalesce((SELECT json_agg(json_build_array(round(p.lat::numeric, 2), round(p.lng::numeric, 2), p.e)) FROM (
        SELECT DISTINCT ON (d.org_id) d.lat, d.lng,
               CASE o.eligibility WHEN 'eligible_verified' THEN 2 WHEN 'eligible_claimed' THEN 1 ELSE 0 END AS e
          FROM flightbridge.detection d JOIN flightbridge.organisation o ON o.id = d.org_id AND o.deleted_at IS NULL
         ORDER BY d.org_id, d.at DESC LIMIT 20000) p), '[]'),
    'engine', (SELECT json_build_object('at', updated_at, 'runner', value->>'runner', 'engine_off', value->'engine_off')
                 FROM flightbridge.system_setting WHERE key = 'engine_status'),
    'autopilot', (SELECT value FROM flightbridge.system_setting WHERE key = 'autopilot'));
END $$;

REVOKE ALL ON FUNCTION public.api_fb_detector() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_detector() TO authenticated;
