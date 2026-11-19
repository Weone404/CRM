-- 119 down: back to 118 (Ad creatives without Instagram posting).
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-content-ig'; END IF; END $$;
DROP FUNCTION IF EXISTS public.api_content_overview(date);
DROP FUNCTION IF EXISTS public.api_content_item_save(jsonb);
DROP FUNCTION IF EXISTS public.svc_ads_meta_build_work(bigint);
ALTER FUNCTION public.api_content_overview_v118(date) RENAME TO api_content_overview;
ALTER FUNCTION public.api_content_item_save_v118(jsonb) RENAME TO api_content_item_save;
ALTER FUNCTION public.svc_ads_meta_build_work_v118(bigint) RENAME TO svc_ads_meta_build_work;
DROP FUNCTION IF EXISTS public.api_content_comments(bigint);
DROP FUNCTION IF EXISTS public.svc_content_ig_due();
DROP FUNCTION IF EXISTS public.svc_content_ig_account(text, text, text);
DROP FUNCTION IF EXISTS public.svc_content_ig_step(bigint, jsonb);
DROP FUNCTION IF EXISTS public.svc_content_ig_stats(bigint, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.svc_content_comment_get(text);
DROP FUNCTION IF EXISTS public.svc_content_comment_done(text, text, text);
DROP FUNCTION IF EXISTS crm_private.content_ig_wake();
DROP FUNCTION IF EXISTS crm_private.content_stage(public.content_item);
DROP FUNCTION IF EXISTS crm_private.content_caption_default(public.content_item);
DROP FUNCTION IF EXISTS crm_private.content_campaigns();
DROP FUNCTION IF EXISTS crm_private.content_ad_results(bigint, text);
DROP FUNCTION IF EXISTS crm_private.content_ad_slots();
DROP TABLE IF EXISTS public.content_comment;
UPDATE public.ads_meta_strategy SET build = build - 'posts' WHERE build ? 'posts';
ALTER TABLE public.content_item DROP COLUMN IF EXISTS ig, DROP COLUMN IF EXISTS post_ai, DROP COLUMN IF EXISTS post_at,
  DROP COLUMN IF EXISTS approved_at, DROP COLUMN IF EXISTS caption;
DELETE FROM public.ads_config WHERE key IN ('meta_ig_user_id', 'meta_ig_username', 'meta_ig_problem', 'meta_ig_checked_at');
UPDATE public.ads_config SET value = '118', updated_at = now() WHERE key = 'ads_schema';
