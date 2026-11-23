-- 127 Growth > Content: an ad creative ordered from an approved strategy carries everything Reel Studio's concept_of()
-- reads, not only headline / primary_text / visual_brief / persona / angle / cta / sizes (116): also format, hook,
-- outline (array), facts_to_verify (array), est_seconds (number) and script (array: the owner-approved timed script).
-- A field is copied only when the plan creative has it in the right shape. Wrapper-by-rename over 116 (_v126).
DO $$ BEGIN
  IF to_regprocedure('public.api_content_from_strategy_v126(bigint)') IS NULL THEN
    ALTER FUNCTION public.api_content_from_strategy(bigint) RENAME TO api_content_from_strategy_v126;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_content_from_strategy(p_strategy_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_content_from_strategy_v126(p_strategy_id); plan jsonb; c jsonb;
BEGIN
  SELECT v.plan INTO plan FROM public.ads_meta_strategy s
    JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id AND v.version = s.approved_version WHERE s.id = p_strategy_id;
  FOR c IN SELECT value FROM jsonb_array_elements(coalesce(plan->'creatives', '[]')) WHERE value->>'format' IN ('image', 'video') LOOP
    UPDATE public.content_item i SET brief = i.brief || jsonb_strip_nulls(jsonb_build_object(
        'format', c->'format',
        'hook', CASE WHEN jsonb_typeof(c->'hook') = 'string' THEN c->'hook' END,
        'outline', CASE WHEN jsonb_typeof(c->'outline') = 'array' THEN c->'outline' END,
        'facts_to_verify', CASE WHEN jsonb_typeof(c->'facts_to_verify') = 'array' THEN c->'facts_to_verify' END,
        'est_seconds', CASE WHEN jsonb_typeof(c->'est_seconds') = 'number' THEN c->'est_seconds'
                            WHEN c->>'est_seconds' ~ '^\s*\d{1,3}(\.\d+)?\s*$' THEN to_jsonb((c->>'est_seconds')::numeric) END,
        'script', CASE WHEN jsonb_typeof(c->'script') = 'array' THEN c->'script' END))
     WHERE i.strategy_id = p_strategy_id AND i.creative_key = c->>'key'
       AND i.kind = CASE c->>'format' WHEN 'video' THEN 'ad_video' ELSE 'ad_image' END;
  END LOOP;
  RETURN o;
END $$;
REVOKE ALL ON FUNCTION public.api_content_from_strategy_v126(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_content_from_strategy(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_content_from_strategy(bigint) TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '127') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
