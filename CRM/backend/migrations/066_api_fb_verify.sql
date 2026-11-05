-- 066: FlightBridge engine 1.5.0 (24x7 Verify worker). SEVP certified school list upload (kind 'sevp'), and
-- "Re-check" / "I checked" on a school puts it straight back in the Verify worker's queue.

CREATE OR REPLACE FUNCTION public.api_fb_register_upload(p_data jsonb)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE eid uuid := crm_private.fb_admin();
  v_kind text := p_data->>'kind'; v_name text := btrim(coalesce(p_data->>'filename', ''));
  v_b64 text := regexp_replace(coalesce(p_data->>'content_b64', ''), '\s', '', 'g'); v_bytes bytea; v_id bigint; v_sha text;
BEGIN
  IF v_kind IS NULL OR v_kind NOT IN ('faa_part141', 'sevp', 'tc_ftu', 'ircc_dli', 'casa_ato') THEN
    RAISE EXCEPTION 'Unknown list type' USING ERRCODE = 'PT422';
  END IF;
  IF v_name = '' OR length(v_name) > 200 OR v_name !~* '\.(csv|xlsx|txt|tsv|html|htm)$' THEN
    RAISE EXCEPTION 'Choose a CSV, Excel (.xlsx) or saved web page (.html) file' USING ERRCODE = 'PT422';
  END IF;
  IF v_b64 = '' THEN RAISE EXCEPTION 'The file is empty' USING ERRCODE = 'PT422'; END IF;
  IF length(v_b64) > 14000000 THEN RAISE EXCEPTION 'The file is too large (10 MB at most)' USING ERRCODE = 'PT422'; END IF;
  BEGIN
    v_bytes := decode(v_b64, 'base64');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'The file could not be read' USING ERRCODE = 'PT422';
  END;
  v_sha := encode(extensions.digest(v_bytes, 'sha256'), 'hex');
  IF EXISTS (SELECT 1 FROM flightbridge.register_upload WHERE sha256 = v_sha AND status IN ('pending', 'imported')
             AND uploaded_at > now() - interval '1 day') THEN
    RAISE EXCEPTION 'This same file was already uploaded today' USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO flightbridge.register_upload (kind, filename, content_b64, sha256, uploaded_by)
  VALUES (v_kind, v_name, v_b64, v_sha, eid) RETURNING id INTO v_id;
  PERFORM crm_private.fb_audit(eid, 'register_uploaded', 'register', 'upload/' || v_id,
                               jsonb_build_object('kind', v_kind, 'filename', v_name, 'bytes', length(v_bytes), 'sha256', v_sha));
  RETURN json_build_object('id', v_id, 'status', 'pending');
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
  -- the 24x7 Verify worker takes this school again straight away (it may still be waiting for the engine's evidence)
  UPDATE flightbridge.organisation SET verify_next_at = NULL, verify_claim_until = NULL WHERE id = v_org;
  PERFORM crm_private.fb_audit(eid, 'eligibility_' || dec, 'organisation', v_org::text,
    jsonb_build_object('result', result, 'reference', ref, 'note', note, 'by_role', crm_private.fb_role()));
  RETURN json_build_object('eligibility', result);
END $$;
