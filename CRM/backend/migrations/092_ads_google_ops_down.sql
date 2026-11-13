-- Rollback of 092 (ADS Google operations). Drops only what 092 created.
DROP TRIGGER IF EXISTS trg_ads_google_ops_guard ON public.ads_google_ops;
DROP FUNCTION IF EXISTS public.svc_ads_google_op_finish(uuid, text, text, jsonb, jsonb), public.svc_ads_google_op_claim(uuid),
  public.svc_ads_google_op_work(), public.svc_ads_google_snapshot_save(uuid, text, jsonb),
  public.api_ads_google_op_decide(uuid, boolean, text), public.api_ads_google_op_create(uuid, text, jsonb, text, text),
  public.api_ads_google_op_check(uuid, text, jsonb), public.api_ads_google_ops(text, int),
  crm_private.ads_google_ops_guard(), crm_private.ads_google_gate(uuid, text, jsonb, uuid),
  crm_private.ads_g_kw_err(jsonb, boolean), crm_private.ads_g_claim(text), crm_private.ads_g_url_ok(text);
DROP TABLE IF EXISTS public.ads_google_ops, public.ads_google_snapshot;
DELETE FROM public.ads_rules WHERE code IN ('g_claim_phrases', 'g_protected_terms', 'g_no_broad', 'g_ops_per_day', 'g_cpc_max', 'g_geo_ids_max');
DELETE FROM public.ads_config WHERE key IN ('autopilot_google', 'google_allowed_domains');
