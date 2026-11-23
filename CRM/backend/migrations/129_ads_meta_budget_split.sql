-- 129 Meta Ads > Overview > Budget split: one slider between the "CPL ads" and the "NIOS ads" ad sets (owner-approved).
--  * api_ads_meta_budget_split(): the running ad sets of the live Meta campaign(s), each with its daily budget (from Meta:
--    ads-sync meta_health and every finished budget action keep ads_meta_object.info.daily_budget; else the plan's),
--    today's spend, 7-day CRM leads (first_touch adset_id, or an ad of the ad set) and 7-day cost per lead, plus the
--    total (fixed: the sum of the two), the slider step (₹10) and the per-side minimum (ads_config meta_split_min_daily,
--    default ₹40). Ready only with exactly one CPL and one NIOS ad set (NIOS: the ad set's or its plan ad set's name says NIOS).
--  * api_ads_meta_budget_split_save(p_items [{adset, daily}]): approvers only; the total must not change and no side may go
--    under the minimum. One budget request per changed ad set through the approval flow (110), the lower one first, with
--    params {daily, pct, split: true}. Returns ids, guard warnings and self_approve like api_ads_meta_action_request.
--  * Only these split requests may go down to the split minimum; every other budget action keeps meta_action_min_daily
--    (default ₹100): the guard, the action worker (svc_ads_meta_action_work.split_min_daily) and api_ads_meta_action_request
--    (which refuses a 'split' flag) all check it.
-- Wrapper-by-rename (_v128) over 110's ads_meta_action_guard, api_ads_meta_action_request, svc_ads_meta_action_work and
-- svc_ads_meta_action_done.

INSERT INTO public.ads_config (key, value) VALUES ('meta_split_min_daily', '40') ON CONFLICT (key) DO NOTHING;

DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_action_guard_v128(text,text,jsonb,numeric)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_action_guard(text, text, jsonb, numeric) RENAME TO ads_meta_action_guard_v128;
  END IF;
  IF to_regprocedure('public.api_ads_meta_action_request_v128(text,text,text,jsonb,text)') IS NULL THEN
    ALTER FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text) RENAME TO api_ads_meta_action_request_v128;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_action_work_v128()') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_action_work() RENAME TO svc_ads_meta_action_work_v128;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_action_done_v128(bigint,text,jsonb,jsonb,text)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text) RENAME TO svc_ads_meta_action_done_v128;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_split_min() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(nullif(crm_private.ads_cfg('meta_split_min_daily'), '')::numeric, 40) $$;

-- a split request is checked against the split minimum; then 110's checks run on its change (%), with its warnings
CREATE OR REPLACE FUNCTION crm_private.ads_meta_action_guard(p_level text, p_kind text, p_params jsonb, p_current numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE nd numeric; hi numeric := coalesce(nullif(crm_private.ads_cfg('meta_action_max_daily'), '')::numeric, 50000);
BEGIN
  IF p_kind = 'budget' AND p_params->>'split' = 'true' THEN
    nd := nullif(p_params->>'daily', '')::numeric;
    IF nd IS NULL OR nd < crm_private.ads_meta_split_min() OR nd > hi THEN
      RAISE EXCEPTION 'Each side needs ₹% to ₹% a day', crm_private.ads_meta_split_min(), hi USING ERRCODE = 'PT422';
    END IF;
    RETURN crm_private.ads_meta_action_guard_v128(p_level, p_kind, p_params - 'daily', p_current);
  END IF;
  RETURN crm_private.ads_meta_action_guard_v128(p_level, p_kind, p_params, p_current);
END $$;

-- only the Budget split card may ask for a split-floor budget
CREATE OR REPLACE FUNCTION public.api_ads_meta_action_request(p_level text, p_object_id text, p_kind text, p_params jsonb, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(p_params, '{}') ? 'split' THEN RAISE EXCEPTION 'Use Budget split on Overview to split the budget' USING ERRCODE = 'PT422'; END IF;
  RETURN public.api_ads_meta_action_request_v128(p_level, p_object_id, p_kind, p_params, p_reason);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_action_work() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w jsonb := public.svc_ads_meta_action_work_v128();
BEGIN
  RETURN w || jsonb_build_object('split_min_daily', crm_private.ads_meta_split_min());
END $$;

-- the budget Meta reads back after a change is kept on the ad set
CREATE OR REPLACE FUNCTION public.svc_ads_meta_action_done(p_id bigint, p_status text, p_before jsonb, p_after jsonb, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.ads_meta_action;
BEGIN
  PERFORM public.svc_ads_meta_action_done_v128(p_id, p_status, p_before, p_after, p_error);
  SELECT * INTO a FROM public.ads_meta_action WHERE id = p_id;
  IF a.kind = 'budget' AND a.status = 'done' AND jsonb_typeof(p_after->'daily_budget') = 'number' THEN
    UPDATE public.ads_meta_object SET info = info || jsonb_build_object('daily_budget', p_after->'daily_budget', 'budget_at', now())
     WHERE level = a.level AND external_id = a.object_id;
  END IF;
END $$;

-- ads-sync meta_health: the daily budgets of the running ad sets (rupees), every 15 minutes while ads run
CREATE OR REPLACE FUNCTION public.svc_ads_meta_budgets_save(p_items jsonb) RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH u AS (
    UPDATE public.ads_meta_object o SET info = o.info || jsonb_build_object('daily_budget', (x->>'daily_budget')::numeric, 'budget_at', now())
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]' END) x
     WHERE o.level = 'adset' AND o.external_id = x->>'id' AND jsonb_typeof(x->'daily_budget') = 'number'
    RETURNING 1)
  SELECT count(*)::int FROM u $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_budget_split() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE today date := crm_private.ads_meta_today(); from7 timestamptz; items jsonb; n_nios int; n_cpl int; tot numeric;
BEGIN
  PERFORM crm_private.ads_require_view();
  from7 := (today - 6)::timestamp AT TIME ZONE 'Asia/Kolkata';
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'nios')::boolean, r->>'name'), '[]') INTO items FROM (
    SELECT jsonb_build_object('id', o.external_id, 'name', o.name, 'nios', z.nios, 'label', CASE WHEN z.nios THEN 'NIOS ads' ELSE 'CPL ads' END,
             'daily', coalesce(nullif(o.info->>'daily_budget', '')::numeric, p.daily),
             'budget_from', CASE WHEN nullif(o.info->>'daily_budget', '') IS NOT NULL THEN 'meta' WHEN p.daily IS NOT NULL THEN 'plan' END,
             'today_spend', coalesce((SELECT sum(d.spend) FROM public.ads_meta_ad_day d WHERE d.adset_ext = o.external_id AND d.day = today), 0),
             'spend_7d', s7.spend, 'leads_7d', l7.n, 'cpl_7d', CASE WHEN l7.n > 0 THEN round(s7.spend / l7.n) END,
             'waiting', EXISTS (SELECT 1 FROM public.ads_meta_action a WHERE a.object_id = o.external_id AND a.kind = 'budget'
                                  AND a.status IN ('pending', 'approved', 'executing'))) r
      FROM public.ads_meta_object o
      JOIN public.ads_meta_object c ON c.level = 'campaign' AND c.external_id = o.campaign_ext AND upper(coalesce(c.status, '')) = 'ACTIVE'
      LEFT JOIN LATERAL (   -- the plan's ad set this one was built from
        SELECT a->>'name' AS name, nullif(a->>'daily_budget', '')::numeric AS daily
          FROM public.ads_meta_strategy st
          JOIN LATERAL jsonb_each(st.build->'steps') e ON e.key LIKE 'adset:%' AND e.value->>'id' = o.external_id
          JOIN public.ads_meta_strategy_version v ON v.strategy_id = st.id AND v.version = coalesce((st.build->>'version')::int, st.approved_version)
          JOIN LATERAL jsonb_array_elements(coalesce(v.plan->'campaigns', '[]')) cp ON true
          JOIN LATERAL jsonb_array_elements(coalesce(cp->'adsets', '[]')) a ON a->>'key' = split_part(e.key, ':', 2)
         LIMIT 1) p ON true
      CROSS JOIN LATERAL (SELECT coalesce(o.name, '') ~* 'nios' OR coalesce(p.name, '') ~* 'nios' AS nios) z
      CROSS JOIN LATERAL (SELECT coalesce(sum(d.spend), 0) AS spend FROM public.ads_meta_ad_day d WHERE d.adset_ext = o.external_id AND d.day >= today - 6) s7
      CROSS JOIN LATERAL (SELECT count(*)::int AS n FROM public.ads_lead l
                           WHERE l.deleted_at IS NULL AND NOT l.quarantined AND l.created_at >= from7
                             AND (l.first_touch->>'adset_id' = o.external_id
                                  OR l.first_touch->>'ad_id' IN (SELECT ad.external_id FROM public.ads_meta_object ad WHERE ad.level = 'ad' AND ad.adset_ext = o.external_id))) l7
     WHERE o.level = 'adset' AND upper(coalesce(o.status, '')) = 'ACTIVE' AND o.account_id = (crm_private.ads_meta_acct()).id) q;
  SELECT count(*) FILTER (WHERE (x->>'nios')::boolean), count(*) FILTER (WHERE NOT (x->>'nios')::boolean),
         CASE WHEN bool_and(x->>'daily' IS NOT NULL) THEN sum((x->>'daily')::numeric) END
    INTO n_nios, n_cpl, tot FROM jsonb_array_elements(items) x;
  RETURN jsonb_build_object('items', items, 'total', tot, 'step', 10, 'min', crm_private.ads_meta_split_min(),
    'ready', n_nios = 1 AND n_cpl = 1 AND tot IS NOT NULL,
    'why', CASE WHEN jsonb_array_length(items) < 2 OR n_nios = 0 THEN 'Appears when the NIOS ad set is live'
                WHEN n_nios <> 1 OR n_cpl <> 1 THEN 'Works when one CPL and one NIOS ad set are running'
                WHEN tot IS NULL THEN 'Waiting for the ad set budgets from Meta' END,
    'can_approve', crm_private.ads_can_approve());
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_budget_split_save(p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE sp jsonb; it jsonb; x jsonb; nd numeric; cur numeric; ids jsonb := '[]'; g jsonb := '[]'; nid bigint; total numeric := 0; txt text;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only approvers can ask for changes' USING ERRCODE = 'PT403'; END IF;
  sp := public.api_ads_meta_budget_split();
  IF NOT (sp->>'ready')::boolean THEN RAISE EXCEPTION '%', coalesce(sp->>'why', 'Budget split is not ready') USING ERRCODE = 'PT409'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) <> 2
     OR (SELECT count(DISTINCT y->>'adset') FROM jsonb_array_elements(p_items) y) <> 2
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) y WHERE NOT (sp->'items') @> jsonb_build_array(jsonb_build_object('id', y->>'adset'))) THEN
    RAISE EXCEPTION 'Give a daily budget for both ad sets' USING ERRCODE = 'PT422';
  END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(x->>'daily', '') !~ '^\d{1,6}$' THEN RAISE EXCEPTION 'Budgets are whole rupees' USING ERRCODE = 'PT422'; END IF;
    IF (x->>'daily')::numeric < (sp->>'min')::numeric THEN
      RAISE EXCEPTION 'Each side needs at least ₹% a day', sp->>'min' USING ERRCODE = 'PT422';
    END IF;
    total := total + (x->>'daily')::numeric;
  END LOOP;
  IF total <> (sp->>'total')::numeric THEN RAISE EXCEPTION 'The total must stay ₹% a day', sp->>'total' USING ERRCODE = 'PT422'; END IF;
  txt := (SELECT string_agg(i->>'label' || ' ₹' || (y->>'daily'), ' / ' ORDER BY (i->>'nios')::boolean)
            FROM jsonb_array_elements(sp->'items') i JOIN jsonb_array_elements(p_items) y ON y->>'adset' = i->>'id');
  -- the lower budget first, so the two never add up to more than the total in Meta
  FOR it, x IN SELECT i, y FROM jsonb_array_elements(sp->'items') i JOIN jsonb_array_elements(p_items) y ON y->>'adset' = i->>'id'
                ORDER BY (y->>'daily')::numeric - (i->>'daily')::numeric LOOP
    nd := (x->>'daily')::numeric; cur := (it->>'daily')::numeric;
    CONTINUE WHEN nd = cur;
    nid := crm_private.ads_meta_action_add('adset', it->>'id', 'budget',
      jsonb_build_object('daily', nd, 'pct', round(100 * (nd - cur) / nullif(cur, 0), 1), 'split', true),
      'Budget split from Overview: ' || txt, 'user', NULL, NULL, auth.uid());
    IF nid IS NULL THEN RAISE EXCEPTION 'A budget change is already waiting for %', it->>'label' USING ERRCODE = 'PT409'; END IF;
    ids := ids || to_jsonb(nid);
    g := g || (SELECT guard FROM public.ads_meta_action WHERE id = nid);
  END LOOP;
  IF jsonb_array_length(ids) = 0 THEN RAISE EXCEPTION 'Nothing changed' USING ERRCODE = 'PT422'; END IF;
  RETURN jsonb_build_object('ids', ids, 'guard', (SELECT coalesce(jsonb_agg(DISTINCT v), '[]') FROM jsonb_array_elements(g) v),
    'self_approve', crm_private.ads_cfg('meta_actions_two_person') <> 'true');
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_split_min(), crm_private.ads_meta_action_guard(text, text, jsonb, numeric),
  crm_private.ads_meta_action_guard_v128(text, text, jsonb, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_action_request_v128(text, text, text, jsonb, text), public.svc_ads_meta_action_work_v128(),
  public.svc_ads_meta_action_done_v128(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_action_work(), public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text),
  public.svc_ads_meta_budgets_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_action_work(), public.svc_ads_meta_action_done(bigint, text, jsonb, jsonb, text), public.svc_ads_meta_budgets_save(jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text), public.api_ads_meta_budget_split(), public.api_ads_meta_budget_split_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_action_request(text, text, text, jsonb, text), public.api_ads_meta_budget_split(), public.api_ads_meta_budget_split_save(jsonb) TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '129') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
