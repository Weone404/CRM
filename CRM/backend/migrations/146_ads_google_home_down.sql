-- Rollback of 146 (Google Ads home screen: balance from Google, one daily amount). Nothing in Google Ads is changed by this file.
-- Refuses while budget_set operations exist (their history would break the kind check).
-- Afterwards re-run 145_ads_google_schedule.sql: it restores the 145 versions of the work lists, the owner-only rule and the job.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind = 'budget_set') THEN
    RAISE EXCEPTION 'Operations of kind budget_set exist; 146 cannot be rolled back while they do.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-google-billing';
  END IF;
  IF to_regprocedure('crm_private.ads_google_gate_v145(uuid,text,jsonb,uuid)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS crm_private.ads_google_gate(uuid, text, jsonb, uuid);
    ALTER FUNCTION crm_private.ads_google_gate_v145(uuid, text, jsonb, uuid) RENAME TO ads_google_gate;
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_ads_google_budget_applied ON public.ads_google_ops;
DROP FUNCTION IF EXISTS crm_private.ads_google_budget_applied();
DROP FUNCTION IF EXISTS public.api_ads_google_home(int);
DROP FUNCTION IF EXISTS public.api_ads_google_budget_set(numeric);
DROP FUNCTION IF EXISTS public.api_ads_google_balance_refresh();
DROP FUNCTION IF EXISTS public.svc_ads_google_billing_save(uuid, jsonb, timestamptz);
DROP FUNCTION IF EXISTS crm_private.ads_google_ops_kick(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_google_snap(uuid, text);
DROP FUNCTION IF EXISTS crm_private.ads_ts(text);
DROP FUNCTION IF EXISTS crm_private.ads_num(text);
DROP TABLE IF EXISTS public.ads_google_topups;
DROP TABLE IF EXISTS public.ads_google_balance;

ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget',
    'campaign_create', 'income_filter', 'ad_schedule'));
DELETE FROM public.ads_rules WHERE code = 'g_daily_total';
DELETE FROM public.ads_config WHERE key IN ('google_campaign_labels', 'google_areas_waiting');
-- The "Money and budget" note in google_brand_facts is kept; the daily and monthly limits stay as the owner last set them.
