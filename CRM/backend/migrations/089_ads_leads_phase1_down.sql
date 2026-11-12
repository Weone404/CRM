-- Rollback of 089_ads_leads_phase1.sql.
-- Removes only the ADS Phase 1 objects (089 never changed anything outside ADS). WARNING: this drops Ads leads, enquiry log, consent history and student links.
-- Export them first if any real data exists:  SELECT * FROM public.ads_lead; ... (or a pg_dump of these tables).
DROP FUNCTION IF EXISTS public.svc_ads_ingest_enquiry(jsonb,text);

DROP FUNCTION IF EXISTS public.api_ads_consent_record(text,text,text,text,text,text,text);
DROP FUNCTION IF EXISTS public.api_ads_lead_set_stage(uuid,text,text,jsonb);
DROP FUNCTION IF EXISTS public.api_ads_lead_assign(uuid,uuid,text);
DROP FUNCTION IF EXISTS public.api_ads_lead_log_contact(uuid,text,text,text);
DROP FUNCTION IF EXISTS public.api_ads_lead_quarantine(uuid,boolean,text);
DROP FUNCTION IF EXISTS public.api_ads_lead_list(text,text,boolean,integer,integer);
DROP FUNCTION IF EXISTS public.api_ads_lead(uuid);
DROP FUNCTION IF EXISTS public.api_ads_counsellor_credit(text,date,date);
DROP FUNCTION IF EXISTS public.api_ads_student_links_propose();
DROP FUNCTION IF EXISTS public.api_ads_student_link_decide(bigint,boolean,text);
DROP FUNCTION IF EXISTS public.api_ads_retention_run(boolean,timestamptz);
DROP FUNCTION IF EXISTS public.api_ads_retention_policy_set(text,integer,boolean,text);

DROP TABLE IF EXISTS public.ads_retention_run, public.ads_retention_policy, public.ads_student_link,
  public.ads_consent_event, public.ads_lead_contact, public.ads_lead_assignment, public.ads_lead_stage_event,
  public.ads_enquiry, public.ads_lead, public.ads_stage_def, public.ads_site;

DROP FUNCTION IF EXISTS crm_private.ads_ingest_enquiry(jsonb,text);
DROP FUNCTION IF EXISTS crm_private.ads_retention_candidates(timestamptz);
DROP FUNCTION IF EXISTS crm_private.ads_student_link_propose();
DROP FUNCTION IF EXISTS crm_private.ads_consent_allows(text,text,text);
DROP FUNCTION IF EXISTS crm_private.ads_consent_status(text,text,text);
DROP FUNCTION IF EXISTS crm_private.ads_require_lead_edit();
DROP FUNCTION IF EXISTS crm_private.ads_role();
DROP FUNCTION IF EXISTS crm_private.ads_touch_is_non_direct(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_touch_is_ads(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_touch_from(jsonb);
DROP FUNCTION IF EXISTS crm_private.ads_append_only();
DROP FUNCTION IF EXISTS crm_private.ads_url_host(text);
DROP FUNCTION IF EXISTS crm_private.ads_jtext(jsonb,text,integer);
DROP FUNCTION IF EXISTS crm_private.ads_email_norm(text);
DROP FUNCTION IF EXISTS crm_private.ads_phone_kind(text);
DROP FUNCTION IF EXISTS crm_private.ads_phone_e164(text);

ALTER TABLE public.ads_access DROP CONSTRAINT IF EXISTS ads_access_role_chk;
ALTER TABLE public.ads_access DROP COLUMN IF EXISTS role;
