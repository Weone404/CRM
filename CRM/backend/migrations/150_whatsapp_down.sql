-- Rolls back 150 (WhatsApp). Removes the two lead triggers first, so Leads keep working exactly as before.
-- WARNING: deletes every WhatsApp chat, message and setting. The Vault keys (wa_*) are kept; delete them in
-- Supabase > Vault if you want them gone too. Leads, ads leads and their notes are not touched.
DROP TRIGGER IF EXISTS wa_lead_in ON public.lead;
DO $$
BEGIN
  IF to_regclass('public.ads_lead') IS NOT NULL THEN DROP TRIGGER IF EXISTS wa_ads_lead_in ON public.ads_lead; END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-wa-worker';
  END IF;
END $$;

DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE (n.nspname = 'public' AND (p.proname LIKE 'api\_wa\_%' OR p.proname LIKE 'svc\_wa\_%'))
               OR (n.nspname = 'crm_private' AND p.proname LIKE 'wa\_%') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', f);
  END LOOP;
END $$;

DROP TABLE IF EXISTS public.wa_setup_check, public.wa_webhook_raw, public.wa_error, public.wa_event, public.wa_note,
  public.wa_reply_rule, public.wa_flow_step, public.wa_template, public.wa_queue, public.wa_message, public.wa_conversation,
  public.wa_contact, public.wa_number, public.wa_settings, public.wa_access;
