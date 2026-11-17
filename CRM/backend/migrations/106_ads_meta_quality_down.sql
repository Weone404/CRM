-- Rollback of 106_ads_meta_quality.sql. Puts 105 back (lead scores are dropped).
DROP TRIGGER IF EXISTS trg_ads_lead_score ON public.ads_meta_lead_archive;
DROP FUNCTION IF EXISTS public.api_ads_meta_lead_quality(date, date, text), public.api_ads_lead_scores(uuid[]), public.api_ads_meta_scored_leads(int),
  public.api_ads_lead_score_settings(), public.api_ads_lead_score_save(jsonb, int, int), crm_private.ads_lead_score_trg(),
  crm_private.ads_lead_score_save(bigint), crm_private.ads_lead_score_calc(bigint), crm_private.ads_meta_lead_facts(date, date);
DROP TABLE IF EXISTS public.ads_lead_score;
DELETE FROM public.ads_config WHERE key IN ('lead_score_rules', 'lead_score_hot', 'lead_score_warm');
UPDATE public.ads_config SET value = '105', updated_at = now() WHERE key = 'ads_schema';
