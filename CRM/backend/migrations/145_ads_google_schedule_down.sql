-- Rollback of 145 (time-of-day bids). Nothing in Google Ads is changed by this file. Refuses while ad_schedule operations exist.
-- Afterwards re-run 144_ads_google_premium.sql: it restores the 144 versions of the work lists, the owner-only rule and the job.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind = 'ad_schedule') THEN
    RAISE EXCEPTION 'Operations of kind ad_schedule exist; 145 cannot be rolled back while they do.';
  END IF;
  IF to_regprocedure('crm_private.ads_google_gate_v144(uuid,text,jsonb,uuid)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_google_gate(uuid, text, jsonb, uuid);
    ALTER FUNCTION crm_private.ads_google_gate_v144(uuid, text, jsonb, uuid) RENAME TO ads_google_gate;
  END IF;
END $$;
ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget',
    'campaign_create', 'income_filter'));
-- The research block in google_brand_facts is kept: it is still what the data showed.
