-- Undo 148: back to one website. Keeps the main website's numbers; other websites and their numbers are deleted.
-- After this, re-run 112_crm_website.sql and 113_crm_website_trend.sql to restore the single-website functions and cron jobs.
DROP FUNCTION IF EXISTS public.api_web_sites(), public.api_web_shared(int), public.api_web_site_save(uuid, text, text, text, text, text, text, text[], text),
  public.api_web_site_remove(uuid), public.api_web_prefs_save(text, text), public.api_web_settings(uuid), public.api_web_overview(uuid),
  public.api_web_queries(text, text, int, uuid), public.api_web_trend(uuid), public.api_web_copilot_upload(text, jsonb, uuid),
  public.svc_web_work(uuid), public.svc_web_save(text, text[], jsonb, uuid), public.svc_web_pages_save(jsonb, uuid), public.svc_web_check_save(text, jsonb, uuid),
  public.svc_web_checks_prune(text, text[], uuid), public.svc_web_run_begin(text, uuid), crm_private.web_queries(uuid);
DELETE FROM public.web_site WHERE NOT is_primary;
ALTER TABLE public.web_row DROP CONSTRAINT IF EXISTS web_row_pkey, ADD PRIMARY KEY (src, kind, k1, k2, win);
ALTER TABLE public.web_page DROP CONSTRAINT IF EXISTS web_page_pkey, ADD PRIMARY KEY (url);
ALTER TABLE public.web_check DROP CONSTRAINT IF EXISTS web_check_pkey, ADD PRIMARY KEY (key);
ALTER TABLE public.web_copilot DROP CONSTRAINT IF EXISTS web_copilot_pkey, ADD PRIMARY KEY (kind, k);
ALTER TABLE public.web_row DROP COLUMN IF EXISTS site_id;
ALTER TABLE public.web_page DROP COLUMN IF EXISTS site_id;
ALTER TABLE public.web_check DROP COLUMN IF EXISTS site_id;
ALTER TABLE public.web_copilot DROP COLUMN IF EXISTS site_id;
ALTER TABLE public.web_run DROP COLUMN IF EXISTS site_id;
CREATE INDEX IF NOT EXISTS idx_web_run_job ON public.web_run (job, started_at DESC);
DROP FUNCTION IF EXISTS crm_private.web_site_id(uuid), crm_private.web_site_url(uuid), crm_private.web_site_gsc(uuid), crm_private.web_site_ga4(uuid), crm_private.web_site_leads(uuid);
DROP TABLE IF EXISTS public.web_site;
DROP FUNCTION IF EXISTS crm_private.web_brand_re(text);
