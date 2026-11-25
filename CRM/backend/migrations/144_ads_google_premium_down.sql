-- Rollback of 144 (premium targeting operations). Nothing in Google Ads is changed by this file.
-- Refuses while operations of the new kinds exist (their history would break the kind check); remove or keep them first.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind IN ('campaign_create', 'income_filter')) THEN
    RAISE EXCEPTION 'Operations of kind campaign_create / income_filter exist; 144 cannot be rolled back while they do.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-google-build';
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_ads_google_ops_owner_only ON public.ads_google_ops;
DROP FUNCTION IF EXISTS crm_private.ads_google_ops_owner_only();
DROP TRIGGER IF EXISTS trg_ads_google_campaign_applied ON public.ads_google_ops;
DROP FUNCTION IF EXISTS crm_private.ads_google_campaign_applied();
DROP FUNCTION IF EXISTS public.svc_ads_google_build_work();
DROP FUNCTION IF EXISTS public.svc_ads_google_build_peek(uuid);
DROP FUNCTION IF EXISTS public.svc_ads_google_build_checked(uuid, boolean, text);
DROP FUNCTION IF EXISTS crm_private.ads_google_build_payload(public.ads_google_ops);

-- the 099 work list (every kind)
CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind,
      'payload', CASE WHEN o.kind = 'budget' THEN o.payload || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->>'campaign_id'))
        ELSE o.payload END,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes')) END
$$;
REVOKE ALL ON FUNCTION public.svc_ads_google_op_work() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_op_work() TO service_role;

-- the old gate back under its own name
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_google_gate_v143(uuid,text,jsonb,uuid)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_google_gate(uuid, text, jsonb, uuid);
    ALTER FUNCTION crm_private.ads_google_gate_v143(uuid, text, jsonb, uuid) RENAME TO ads_google_gate;
  END IF;
END $$;

ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget'));

DELETE FROM public.ads_rules WHERE code IN ('g_campaigns_per_day', 'g_campaign_locations_max');
DELETE FROM public.ads_config WHERE key = 'google_targeting_locked';
-- The owner's decisions in google_brand_facts and the playbook lesson are kept: they are still what the owner decided.
