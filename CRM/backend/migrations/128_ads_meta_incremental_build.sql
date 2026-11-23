-- 128 Meta Ads > Strategy > Create in Meta for a newer approved version of a strategy that is already running.
--  * Before: any version after the first built one was refused ("Version 3 was already created in Meta").
--  * Now (incremental): what the new version shares with the built one by key is kept and reused (e.g. campaign:c1, and
--    the Instagram posts in build.posts such as v1's); only the new keys are created (form:f2, adset:a2, creative:*:f2,
--    ad:a2:*), PAUSED as always. Meta forms cannot be edited, so a changed form must use a new key; a reused object is
--    not changed in Meta (build.reused lists them so the owner can edit them in Ads Manager if needed).
--  * The old ad sets the new version no longer has are NOT paused here: one pause request each goes into the approval
--    queue (Meta Ads > Automate, 110), to approve on the day the new ad set goes live. It waits 14 days, not 3.
--  * The old steps stay in build.steps, so the running test, its leads and its ads keep showing in Overview and in the
--    agents' last_test. build.base_version / retired record what came from the earlier version.
--  * Form answers decode with the newest version (up to the built one) that has the form's key, so leads from a form of
--    an earlier version (f1) still read in words after v5 is built.
-- Wrapper-by-rename over 104 (api_ads_meta_strategy_build) and 124 (ads_meta_answer_text), both _v127.

DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_strategy_build_v127(bigint)') IS NULL THEN
    ALTER FUNCTION public.api_ads_meta_strategy_build(bigint) RENAME TO api_ads_meta_strategy_build_v127;
  END IF;
  IF to_regprocedure('crm_private.ads_meta_answer_text_v127(text,jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_answer_text(text, jsonb) RENAME TO ads_meta_answer_text_v127;
  END IF;
END $$;

-- every step key an approved plan builds (same keys as meta_build.ts planSteps)
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_keys(p_plan jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT k), '{}') FROM (
    SELECT 'form:' || (f->>'key') k FROM jsonb_array_elements(coalesce(p_plan->'forms', '[]')) f
    UNION ALL SELECT 'campaign:' || (c->>'key') FROM jsonb_array_elements(coalesce(p_plan->'campaigns', '[]')) c
    UNION ALL SELECT 'adset:' || (a->>'key') FROM jsonb_array_elements(coalesce(p_plan->'campaigns', '[]')) c, jsonb_array_elements(coalesce(c->'adsets', '[]')) a
    UNION ALL SELECT 'creative:' || (x #>> '{}') || ':' || (a->>'form') FROM jsonb_array_elements(coalesce(p_plan->'campaigns', '[]')) c,
                jsonb_array_elements(coalesce(c->'adsets', '[]')) a, jsonb_array_elements(coalesce(a->'ads', '[]')) x
    UNION ALL SELECT 'ad:' || (a->>'key') || ':' || (x #>> '{}') FROM jsonb_array_elements(coalesce(p_plan->'campaigns', '[]')) c,
                jsonb_array_elements(coalesce(c->'adsets', '[]')) a, jsonb_array_elements(coalesce(a->'ads', '[]')) x) z $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_strategy_build(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; plan jsonb; keys text[]; reused text[]; retired text[]; built int; o jsonb; e record; nid bigint; asks jsonb := '[]';
BEGIN
  PERFORM crm_private.ads_require_admin();
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_id FOR UPDATE;
  built := nullif(s.build->>'version', '')::int;
  -- first build, a retry of the same version, or an older version: as before (104 refuses the last case)
  IF s.id IS NULL OR s.approved_version IS NULL OR s.status <> 'approved' OR built IS NULL OR s.approved_version <= built
     OR jsonb_typeof(s.build->'steps') IS DISTINCT FROM 'object'
     OR NOT EXISTS (SELECT 1 FROM jsonb_each(s.build->'steps') x WHERE x.value->>'id' IS NOT NULL) THEN
    RETURN public.api_ads_meta_strategy_build_v127(p_id);
  END IF;
  SELECT v.plan INTO plan FROM public.ads_meta_strategy_version v WHERE v.strategy_id = s.id AND v.version = s.approved_version;
  keys := crm_private.ads_meta_plan_keys(plan);
  reused := ARRAY(SELECT x.key FROM jsonb_each(s.build->'steps') x WHERE x.value->>'id' IS NOT NULL AND x.key = ANY (keys) ORDER BY x.key);
  retired := ARRAY(SELECT x.key FROM jsonb_each(s.build->'steps') x WHERE x.value->>'id' IS NOT NULL AND NOT (x.key = ANY (keys)) ORDER BY x.key);
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('version', s.approved_version, 'base_version', built,
      'reused', to_jsonb(reused), 'retired', to_jsonb(retired), 'incremental_at', now()), updated_at = now() WHERE id = p_id;
  o := public.api_ads_meta_strategy_build_v127(p_id);   -- same checks (account, Page, not already running); queues the build
  -- the old ad sets this version drops: a pause request each, approved by a person when the new ad set goes live
  FOR e IN SELECT x.key, x.value->>'id' AS id FROM jsonb_each(s.build->'steps') x
            WHERE x.key LIKE 'adset:%' AND x.key = ANY (retired) AND x.value->>'id' ~ '^[0-9]{3,25}$' ORDER BY x.key LOOP
    nid := crm_private.ads_meta_action_add('adset', e.id, 'pause', '{}',
      format('Strategy %s version %s replaces this ad set (%s from version %s). Approve on the day the new ad set goes live.',
             s.id, s.approved_version, split_part(e.key, ':', 2), built), 'user', NULL, NULL, auth.uid());
    IF nid IS NOT NULL THEN UPDATE public.ads_meta_action SET expires_at = now() + interval '14 days' WHERE id = nid; END IF;
    asks := asks || jsonb_build_object('adset', e.id, 'action_id', coalesce(nid, (SELECT a.id FROM public.ads_meta_action a WHERE a.object_id = e.id AND a.kind = 'pause'
                                         AND a.status IN ('pending', 'approved', 'executing') LIMIT 1)));
  END LOOP;
  UPDATE public.ads_meta_strategy SET build = build || jsonb_build_object('pause_requests', asks) WHERE id = p_id;
  PERFORM crm_private.ads_log('meta_build_incremental', 'meta_strategy', p_id::text,
    jsonb_build_object('from', built, 'to', s.approved_version, 'reused', reused, 'retired', retired));
  RETURN o || jsonb_build_object('incremental', true, 'base_version', built, 'reused', to_jsonb(reused), 'retired', to_jsonb(retired), 'pause_requests', asks);
END $$;

-- q1 / q1o2 -> question and option text, from the newest version (up to the built one) that has this form's key
CREATE OR REPLACE FUNCTION crm_private.ads_meta_answer_text(p_form text, p_answers jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE qs jsonb; out jsonb := '[]'; k text; v text; n int; o int; q jsonb;
BEGIN
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' THEN RETURN '[]'; END IF;
  SELECT coalesce(jsonb_agg(x ORDER BY ord), '[]') INTO qs FROM (
    SELECT x, ord FROM public.ads_meta_strategy s
      JOIN LATERAL jsonb_each(s.build->'steps') e ON e.key LIKE 'form:%' AND e.value->>'id' = p_form
      JOIN public.ads_meta_strategy_version ver ON ver.strategy_id = s.id AND ver.version = (
             SELECT max(x2.version) FROM public.ads_meta_strategy_version x2
              WHERE x2.strategy_id = s.id AND x2.version <= coalesce((s.build->>'version')::int, s.approved_version)
                AND x2.plan->'forms' @> jsonb_build_array(jsonb_build_object('key', split_part(e.key, ':', 2))))
      JOIN LATERAL jsonb_array_elements(ver.plan->'forms') f ON f->>'key' = split_part(e.key, ':', 2)
      JOIN LATERAL jsonb_array_elements(f->'questions') WITH ORDINALITY qq(x, ord) ON x->>'type' = 'CUSTOM'
     WHERE p_form IS NOT NULL LIMIT 20) z;
  FOR k, v IN SELECT key, value #>> '{}' FROM jsonb_each(p_answers) ORDER BY key LOOP
    n := nullif(substring(k FROM '^q(\d+)$'), '')::int;
    IF n IS NOT NULL AND n <= jsonb_array_length(qs) THEN
      q := qs->(n - 1);
      o := nullif(substring(v FROM '^q\d+o(\d+)$'), '')::int;
      out := out || jsonb_build_object('q', q->>'label', 'a', coalesce(q->'options'->>(o - 1), v));
    ELSIF k !~* '(name|phone|email|mobile|number)' THEN
      out := out || jsonb_build_object('q', initcap(replace(k, '_', ' ')), 'a', v);
    END IF;
  END LOOP;
  RETURN out;
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_plan_keys(jsonb), crm_private.ads_meta_answer_text(text, jsonb), crm_private.ads_meta_answer_text_v127(text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_strategy_build_v127(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_strategy_build(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_strategy_build(bigint) TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '128') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
