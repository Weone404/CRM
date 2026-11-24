-- 134: Meta Ads > Overview ad list fixes (seen 24 Nov 2026 after strategy 1 version 7 went live).
--  * Plan steps never created in Meta (no id: an ad waiting for its video, an ad of an ad set Meta refused) were listed as
--    "Paused" ads with ₹0, and all of them had the same empty React key. Only ads that exist in Meta are listed now.
--  * An ad whose creative left the current plan (v2 after it was retired) showed its key ("v2") as its name: the name now
--    comes from the newest version that has that creative (creatives or reserve_creatives).
--  * Ads of a retired ad set (the old Delhi test) read like a second copy of the live ad: they are marked "· old test"
--    and listed after the live ones (live first, then by spend).
--  * A pause / switch-on done from the CRM showed the old status until the 3-hourly object sync: the done change now
--    writes Meta's new status into ads_meta_object at once (an ad set's ads follow it: ADSET_PAUSED / back to ACTIVE).
-- Wrappers over 124 (api_ads_meta_live, renamed _v133) and 129 (svc_ads_meta_action_done, renamed _v133).
-- Re-runnable. Down: 134_ads_meta_live_ads_fix_down.sql.

DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_live_v133()') IS NULL THEN ALTER FUNCTION public.api_ads_meta_live() RENAME TO api_ads_meta_live_v133; END IF;
  IF to_regprocedure('public.svc_ads_meta_action_done_v133(bigint,text,jsonb,jsonb,text)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) RENAME TO svc_ads_meta_action_done_v133;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_object_status_from(p_level text, p_object text, p_after jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE st text := upper(coalesce(nullif(p_after->>'effective_status', ''), nullif(p_after->>'status', '')));
BEGIN
  IF st IS NULL OR p_object IS NULL THEN RETURN; END IF;
  UPDATE public.ads_meta_object SET status = st, updated_at = now() WHERE level = p_level AND external_id = p_object;
  IF p_level = 'adset' AND st = 'PAUSED' THEN
    UPDATE public.ads_meta_object SET status = 'ADSET_PAUSED', updated_at = now() WHERE level = 'ad' AND adset_ext = p_object AND status IN ('ACTIVE', 'IN_PROCESS');
  ELSIF p_level = 'adset' AND st IN ('ACTIVE', 'IN_PROCESS') THEN
    UPDATE public.ads_meta_object SET status = 'ACTIVE', updated_at = now() WHERE level = 'ad' AND adset_ext = p_object AND status = 'ADSET_PAUSED';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_action_done(p_id bigint, p_status text, p_before jsonb, p_after jsonb, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_meta_action;
BEGIN
  PERFORM public.svc_ads_meta_action_done_v133(p_id, p_status, p_before, p_after, p_error);
  SELECT * INTO a FROM public.ads_meta_action WHERE id = p_id;
  IF a.status = 'done' AND a.kind IN ('pause', 'activate') THEN
    PERFORM crm_private.ads_meta_object_status_from(a.level, a.object_id, p_after);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_action_done_v133(bigint, text, jsonb, jsonb, text),
  crm_private.ads_meta_object_status_from(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) TO service_role;

-- the changes done before this migration (e.g. 24 Nov: old Delhi ad set paused, new ad set and ads switched on)
DO $$ DECLARE a public.ads_meta_action; BEGIN
  FOR a IN SELECT * FROM public.ads_meta_action WHERE status = 'done' AND kind IN ('pause', 'activate') AND executed_at > now() - interval '3 hours'
            AND executed_at > coalesce((SELECT max(o.updated_at) FROM public.ads_meta_object o WHERE o.external_id = object_id), '-infinity') - interval '1 hour'
           ORDER BY executed_at LOOP
    PERFORM crm_private.ads_meta_object_status_from(a.level, a.object_id, a.after);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_live() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_ads_meta_live_v133(); camps jsonb := '[]'; c jsonb; st public.ads_meta_strategy; cur jsonb; ads jsonb;
BEGIN
  FOR c IN SELECT value FROM jsonb_array_elements(coalesce(o->'campaigns', '[]')) LOOP
    SELECT * INTO st FROM public.ads_meta_strategy WHERE id = (c->>'strategy_id')::bigint;
    SELECT ver.plan INTO cur FROM public.ads_meta_strategy_version ver
     WHERE ver.strategy_id = st.id AND ver.version = coalesce((st.build->>'version')::int, st.approved_version);
    SELECT coalesce(jsonb_agg(x ORDER BY (x->>'old')::boolean, (x->>'spend')::numeric DESC, x->>'key'), '[]') INTO ads FROM (
      SELECT a || jsonb_build_object(
               'name', CASE WHEN coalesce(a->>'name', '') = '' OR a->>'name' = a->>'key'
                            THEN coalesce((SELECT coalesce(cr->>'headline', cr->>'name') FROM public.ads_meta_strategy_version ver,
                                             jsonb_array_elements(coalesce(ver.plan->'creatives', '[]') || coalesce(ver.plan->'reserve_creatives', '[]')) cr
                                            WHERE ver.strategy_id = st.id AND cr->>'key' = a->>'key' AND coalesce(cr->>'headline', cr->>'name', '') <> ''
                                            ORDER BY ver.version DESC LIMIT 1), a->>'name')
                            ELSE a->>'name' END
                       || CASE WHEN k.adset IS NOT NULL AND NOT (k.adset = ANY (crm_private.ads_meta_plan_keys(cur))) THEN ' · old test' ELSE '' END,
               'old', k.adset IS NOT NULL AND NOT (k.adset = ANY (crm_private.ads_meta_plan_keys(cur)))) x
        FROM jsonb_array_elements(coalesce(c->'ads', '[]')) a
        LEFT JOIN LATERAL (SELECT 'adset:' || split_part(e.key, ':', 2) AS adset FROM jsonb_each(coalesce(st.build->'steps', '{}')) e
                            WHERE e.key LIKE 'ad:%' AND e.value->>'id' = a->>'id' LIMIT 1) k ON true
       WHERE coalesce(a->>'id', '') <> '') q;
    camps := camps || jsonb_build_array(c || jsonb_build_object('ads', ads));
  END LOOP;
  RETURN o || jsonb_build_object('campaigns', camps);
END $$;

REVOKE ALL ON FUNCTION public.api_ads_meta_live(), public.api_ads_meta_live_v133() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_ads_meta_live_v133() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '134') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
