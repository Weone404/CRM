-- 130 Plan check for a split budget: a campaign may run 2+ ad sets below ₹100 a day each (the owner's CPL / NIOS split, e.g.
-- ₹70 / ₹30) when every one of them is at least the split minimum (ads_config meta_split_min_daily, 129) and together they make at
-- least ₹100 a day. A single ad set under ₹100 is still refused. Wrapper-by-rename over the 114 check.
DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_plan_check_v129(jsonb,jsonb)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_plan_check(jsonb, jsonb) RENAME TO ads_meta_plan_check_v129;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.ads_meta_plan_check(p_goal jsonb, p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE pr jsonb := crm_private.ads_meta_plan_check_v129(p_goal, p); ok_sets text[] := '{}'; c jsonb; a jsonb; lo numeric; tot numeric;
        n int; good int; low int; daily numeric := 0; monthly numeric; out jsonb := '[]'; m text; dm text; said boolean := false;
BEGIN
  IF jsonb_typeof(pr) <> 'array' OR jsonb_typeof(p->'campaigns') <> 'array' THEN RETURN pr; END IF;
  lo := coalesce(nullif(crm_private.ads_cfg('meta_split_min_daily'), '')::numeric, 30);
  FOR c IN SELECT value FROM jsonb_array_elements(p->'campaigns') LOOP
    IF c->>'budget_level' = 'adset' AND jsonb_typeof(c->'adsets') = 'array' THEN
      SELECT count(*), count(*) FILTER (WHERE jsonb_typeof(x->'daily_budget') = 'number' AND (x->>'daily_budget')::numeric >= lo),
             count(*) FILTER (WHERE jsonb_typeof(x->'daily_budget') = 'number' AND (x->>'daily_budget')::numeric < 100),
             coalesce(sum(CASE WHEN jsonb_typeof(x->'daily_budget') = 'number' THEN (x->>'daily_budget')::numeric END), 0)
        INTO n, good, low, tot FROM jsonb_array_elements(c->'adsets') x;
      IF n >= 2 AND good = n AND low > 0 AND tot >= 100 THEN
        SELECT ok_sets || array_agg(coalesce(x->>'key', '?')) INTO ok_sets FROM jsonb_array_elements(c->'adsets') x;
      END IF;
    END IF;
    IF c->>'budget_level' = 'campaign' AND jsonb_typeof(c->'daily_budget') = 'number' THEN daily := daily + (c->>'daily_budget')::numeric;
    ELSIF c->>'budget_level' = 'adset' AND jsonb_typeof(c->'adsets') = 'array' THEN
      SELECT daily + coalesce(sum(CASE WHEN jsonb_typeof(x->'daily_budget') = 'number' THEN (x->>'daily_budget')::numeric END), 0)
        INTO daily FROM jsonb_array_elements(c->'adsets') x;
    END IF;
  END LOOP;
  IF cardinality(ok_sets) = 0 THEN RETURN pr; END IF;
  monthly := CASE WHEN jsonb_typeof(p->'budget'->'monthly_total') = 'number' THEN (p->'budget'->>'monthly_total')::numeric END;
  -- the 114 check leaves budgets under ₹100 out of its daily sum: recompute that message with the split ad sets counted
  IF monthly IS NOT NULL AND monthly > 0 AND daily > 0 AND abs(daily * 30.4 - monthly) > monthly * 0.10 THEN
    dm := format('Daily budgets add up to ₹%s a day (₹%s a month), but budget.monthly_total says ₹%s.', round(daily), round(daily * 30.4), round(monthly));
  END IF;
  FOR m IN SELECT value #>> '{}' FROM jsonb_array_elements(pr) LOOP
    CONTINUE WHEN m ~ '^Ad set .+: budget of at least ₹100 a day\.$' AND substring(m FROM '^Ad set (.+): budget') = ANY (ok_sets);
    IF m LIKE 'Daily budgets add up to %' THEN
      said := true;
      IF dm IS NOT NULL THEN out := out || to_jsonb(dm); END IF;
      CONTINUE;
    END IF;
    out := out || to_jsonb(m);
  END LOOP;
  IF dm IS NOT NULL AND NOT said THEN out := out || to_jsonb(dm); END IF;
  RETURN out;
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_meta_plan_check(jsonb, jsonb), crm_private.ads_meta_plan_check_v129(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '130') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
