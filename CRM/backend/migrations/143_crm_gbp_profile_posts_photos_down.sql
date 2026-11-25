-- Rollback of 143: health check, posts and photos go. Posts already published stay on Google.
DROP FUNCTION IF EXISTS public.api_gbp_profile(uuid), public.api_gbp_posts(uuid, int), public.api_gbp_media(uuid, int),
  public.api_gbp_post_create(uuid, text, text, text, text), public.api_gbp_post_cancel(bigint),
  public.svc_gbp_details_save(uuid, jsonb), public.svc_gbp_posts_save(uuid, jsonb, boolean), public.svc_gbp_media_save(uuid, jsonb, int, int, boolean),
  public.svc_gbp_post_queue(int), public.svc_gbp_post_result(bigint, text, text, text), crm_private.gbp_health(uuid);
DROP TABLE IF EXISTS public.gbp_post_out, public.gbp_media, public.gbp_post;
ALTER TABLE public.gbp_location DROP COLUMN IF EXISTS details, DROP COLUMN IF EXISTS details_at, DROP COLUMN IF EXISTS media_owner,
  DROP COLUMN IF EXISTS media_customer, DROP COLUMN IF EXISTS extras_at;
