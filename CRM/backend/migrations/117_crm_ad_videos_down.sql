-- Down for 117: back to 116 (ad videos made in Reel Studio stay as rows; their attachments and the strategies' video ids are kept in JSON).
DROP FUNCTION IF EXISTS public.svc_content_video_meta(bigint, text);
DROP FUNCTION IF EXISTS public.svc_content_video_get(bigint);
DROP FUNCTION IF EXISTS public.svc_content_video(bigint, text, text, numeric);
DROP FUNCTION IF EXISTS public.svc_content_adopt(jsonb);
DROP FUNCTION IF EXISTS public.svc_ads_meta_build_video(bigint, text, text, text, text);
DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_meta_build_work_v116(bigint)') IS NOT NULL THEN
    DROP FUNCTION public.svc_ads_meta_build_work(bigint);
    ALTER FUNCTION public.svc_ads_meta_build_work_v116(bigint) RENAME TO svc_ads_meta_build_work;
  END IF;
  IF to_regprocedure('public.api_content_item_save_v116(jsonb)') IS NOT NULL THEN
    DROP FUNCTION public.api_content_item_save(jsonb);
    ALTER FUNCTION public.api_content_item_save_v116(jsonb) RENAME TO api_content_item_save;
  END IF;
  IF to_regprocedure('public.api_content_overview_v116(date)') IS NOT NULL THEN
    DROP FUNCTION public.api_content_overview(date);
    ALTER FUNCTION public.api_content_overview_v116(date) RENAME TO api_content_overview;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.content_video_slots();
DELETE FROM public.content_item WHERE source = 'studio';
DROP INDEX IF EXISTS public.ux_content_item_studio_job;
ALTER TABLE public.content_item DROP CONSTRAINT IF EXISTS content_item_source_check;
ALTER TABLE public.content_item ADD CONSTRAINT content_item_source_check CHECK (source IN ('planner', 'manual', 'strategy'));
UPDATE public.ads_config SET value = '116', updated_at = now() WHERE key = 'ads_schema';
