-- Undo 149: removes the JustDial links and their log. Leads already received stay in Leads.
DROP FUNCTION IF EXISTS public.api_jd_listings(), public.api_jd_listing_save(uuid, text, text, uuid, boolean), public.api_jd_listing_new_link(uuid),
  public.api_jd_listing_remove(uuid), public.svc_jd_ingest(text, jsonb), crm_private.jd_ingest(text, jsonb);
DROP TABLE IF EXISTS public.jd_hit;
DROP TABLE IF EXISTS public.jd_listing;
