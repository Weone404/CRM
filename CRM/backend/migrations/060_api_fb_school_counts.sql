-- 060: Schools screen: true counts per eligibility section for the current filter. The list itself is capped at
-- 1,000 rows, so counting the loaded rows was wrong once a filter matched more than 1,000 schools.
CREATE OR REPLACE FUNCTION public.api_fb_school_counts(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE f jsonb := coalesce(p_filters, '{}');
  v_country text := nullif(f->>'country', ''); v_status text := nullif(f->>'status', ''); v_q text := nullif(f->>'q', '');
  v_region text := nullif(f->>'region', ''); v_kind text := f->>'kind';
  v_area bigint := crm_private.fb_int(f, 'area_id', NULL, NULL);
BEGIN
  PERFORM crm_private.fb_member();
  IF v_kind NOT IN ('flying_school', 'ground_school') THEN v_kind := NULL; END IF;
  RETURN (SELECT json_build_object(
      'total', count(*),
      'eligible_verified', count(*) FILTER (WHERE o.eligibility = 'eligible_verified'),
      'eligible_claimed', count(*) FILTER (WHERE o.eligibility = 'eligible_claimed'),
      'unqualified', count(*) FILTER (WHERE o.eligibility = 'unqualified'),
      'unknown', count(*) FILTER (WHERE o.eligibility IS NULL OR o.eligibility = 'unknown'))
    FROM flightbridge.organisation o
   WHERE o.deleted_at IS NULL
     AND (v_area IS NULL OR (v_area = 0 AND o.area_id IS NULL) OR (v_area <> 0 AND o.area_id = v_area))
     AND (v_kind IS NULL OR o.org_kind = v_kind)
     AND (v_country IS NULL OR o.country = left(upper(v_country), 2))
     AND (v_region IS NULL OR (v_region = '__none__' AND o.region IS NULL) OR (v_region <> '__none__' AND o.region = v_region))
     AND (v_status IS NULL OR o.status = v_status)
     AND (v_q IS NULL OR o.name ILIKE '%' || v_q || '%' OR o.website_domain ILIKE '%' || v_q || '%'
          OR EXISTS (SELECT 1 FROM flightbridge.regulatory_approval r WHERE r.org_id = o.id AND r.approval_ref ILIKE '%' || v_q || '%')));
END $$;
REVOKE ALL ON FUNCTION public.api_fb_school_counts(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_fb_school_counts(jsonb) TO authenticated;
