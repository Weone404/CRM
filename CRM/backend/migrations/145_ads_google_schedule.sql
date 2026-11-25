-- 145 ADS > Google Ads: time-of-day bids, and the verified research the AI team works from (owner approved, 25 Nov 2026).
-- New owner-only operation:
--   ad_schedule   a campaign's day split into time slots, each with its own bid change (-90% to +900%), the same every day of the
--                 week. The slots must cover all 24 hours: a schedule in Google Ads shows ads ONLY inside its slots, so a gap
--                 would silently switch the ads off. Rows from an earlier schedule are taken out in the same request ("remove").
-- Layered like 144: the 144 gate is renamed to ads_google_gate_v144 and the new gate calls it for everything it already knew.
-- IMPORTANT for later migrations: add a layer the same way, or change the layer that owns the kind; never replace
-- crm_private.ads_google_gate with a full body.
-- Runs in ads-google-ops (with campaign_create and income_filter). Run it twice safely. Rollback: 145_ads_google_schedule_down.sql.

ALTER TABLE public.ads_google_ops DROP CONSTRAINT IF EXISTS ads_google_ops_kind_check;
ALTER TABLE public.ads_google_ops ADD CONSTRAINT ads_google_ops_kind_check
  CHECK (kind IN ('keyword_add', 'negative_add', 'keyword_status', 'rsa_create', 'ad_status', 'ad_group_create', 'campaign_geo',
    'shared_set_attach', 'callout_add', 'asset_unlink', 'sitelink_add', 'conversion_goal', 'cpc_cap', 'budget',
    'campaign_create', 'income_filter', 'ad_schedule'));

-- ---------------------------------------------------------------- gate
DO $$
BEGIN
  IF to_regprocedure('crm_private.ads_google_gate_v144(uuid,text,jsonb,uuid)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) RENAME TO ads_google_gate_v144;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_google_gate(p_account uuid, p_kind text, p_payload jsonb, p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE res jsonb := crm_private.ads_google_gate_v144(p_account, p_kind, p_payload, p_exclude);
        a public.ads_accounts; b jsonb; sl jsonb; nxt int := 0; ok boolean := true; sh int; eh int; pct numeric;
BEGIN
  IF p_kind IS DISTINCT FROM 'ad_schedule' THEN RETURN res; END IF;
  SELECT coalesce(jsonb_agg(bl), '[]') INTO b FROM jsonb_array_elements(res->'blockers') bl WHERE bl #>> '{}' <> 'Unknown operation type.';
  SELECT * INTO a FROM public.ads_accounts WHERE id = p_account;
  IF a.id IS NULL OR a.platform <> 'google' OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('blockers', b, 'warnings', coalesce(res->'warnings', '[]'));
  END IF;
  IF coalesce(p_payload->>'campaign_id', '') !~ '^\d+$' THEN b := b || to_jsonb('campaign_id is required.'::text); END IF;
  IF jsonb_typeof(p_payload->'slots') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'slots') NOT BETWEEN 1 AND 6 THEN
    b := b || to_jsonb('Give 1-6 time slots (Google allows 6 a day).'::text);
  ELSE
    FOR sl IN SELECT v FROM jsonb_array_elements(p_payload->'slots') v LOOP
      BEGIN
        sh := (sl->>'start_hour')::int; eh := (sl->>'end_hour')::int; pct := coalesce((sl->>'bid_pct')::numeric, 0);
      EXCEPTION WHEN others THEN sh := NULL; END;
      IF jsonb_typeof(sl) <> 'object' OR sh IS NULL OR eh IS NULL OR (sl->>'start_hour') !~ '^\d+$' OR (sl->>'end_hour') !~ '^\d+$'
         OR sh NOT BETWEEN 0 AND 23 OR eh NOT BETWEEN 1 AND 24 OR sh >= eh THEN
        b := b || to_jsonb('Every slot needs whole hours: start_hour 0-23 and a later end_hour up to 24.'::text); ok := false; EXIT;
      END IF;
      IF pct <> round(pct) OR pct NOT BETWEEN -90 AND 900 THEN
        b := b || to_jsonb('bid_pct must be a whole number from -90 to 900.'::text); ok := false; EXIT;
      END IF;
      IF sh <> nxt THEN
        b := b || to_jsonb(format('The slots must follow each other from 0 to 24 with no gap or overlap (hour %s is %s).', nxt,
          CASE WHEN sh > nxt THEN 'not covered' ELSE 'covered twice' END)); ok := false; EXIT;
      END IF;
      nxt := eh;
    END LOOP;
    IF ok AND nxt <> 24 THEN
      b := b || to_jsonb(format('The slots stop at %s:00. They must cover all 24 hours, or the ads go off for the rest of the day.', nxt));
    END IF;
  END IF;
  IF p_payload ? 'remove' AND (jsonb_typeof(p_payload->'remove') <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'remove') t
       WHERE jsonb_typeof(t) <> 'string' OR (t #>> '{}') !~ ('^customers/' || a.external_id || '/campaignCriteria/' || coalesce(p_payload->>'campaign_id', '0') || '~\d+$'))) THEN
    b := b || to_jsonb('remove takes this campaign''s own schedule rows (resource names).'::text);
  END IF;
  RETURN jsonb_build_object('blockers', b, 'warnings', coalesce(res->'warnings', '[]'));
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_private.ads_google_gate_v144(uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- owner only, and who runs it
CREATE OR REPLACE FUNCTION crm_private.ads_google_ops_owner_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.created_by_type = 'agent' AND NEW.status = 'approved' AND NEW.approved_by IS NULL
     AND (NEW.kind IN ('campaign_create', 'income_filter', 'ad_schedule')
          OR (NEW.kind = 'campaign_geo' AND crm_private.ads_cfg('google_targeting_locked') = 'on')) THEN
    NEW.status := 'pending'; NEW.approved_at := NULL;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_google_op_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind,
      'payload', CASE WHEN o.kind = 'budget' THEN o.payload || jsonb_build_object('budget_resource',
          (SELECT c.budget_ref FROM public.ads_campaigns c WHERE c.account_id = o.account_id AND c.external_id = o.payload->>'campaign_id'))
        ELSE o.payload END,
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind NOT IN ('campaign_create', 'income_filter', 'ad_schedule')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
CREATE OR REPLACE FUNCTION public.svc_ads_google_build_work() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN crm_private.ads_cfg('execution_paused') = 'true' OR crm_private.ads_cfg('google_paused') = 'true' THEN '[]'::jsonb ELSE (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', crm_private.ads_google_build_payload(o),
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status) ORDER BY o.approved_at), '[]')
      FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
     WHERE o.kind IN ('campaign_create', 'income_filter', 'ad_schedule')
       AND (o.status = 'approved' OR (o.status = 'executing' AND o.executed_at < now() - interval '10 minutes'))) END
$$;
CREATE OR REPLACE FUNCTION public.svc_ads_google_build_peek(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', o.id, 'kind', o.kind, 'payload', crm_private.ads_google_build_payload(o),
      'account_external_id', a.external_id, 'login_customer_id', a.login_customer_id, 'status', o.status)
    FROM public.ads_google_ops o JOIN public.ads_accounts a ON a.id = o.account_id
   WHERE o.id = p_id AND o.kind IN ('campaign_create', 'income_filter', 'ad_schedule') AND o.status IN ('pending', 'approved')
$$;
REVOKE ALL ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work(), public.svc_ads_google_build_peek(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_google_op_work(), public.svc_ads_google_build_work(), public.svc_ads_google_build_peek(uuid) TO service_role;

-- ---------------------------------------------------------------- what the AI team works from (verified research, 25 Nov 2026)
UPDATE public.ads_config SET value = value || E'\nVerified research (25 Nov 2026; sources: CRM leads and students, the Google Ads account, Google Ads Transparency Centre, competitors'' own pages):\n'
  '- Rollout: Tier 1 only for now. Delhi NCR campaign = premium Delhi and Noida PIN codes, Greater Noida, Gurugram, Faridabad, Ghaziabad. Other cities campaign = Chandigarh, Mohali, Panchkula, Punjab. The owner paused Tier 2 (Jaipur, Lucknow, Udaipur, Sonipat, Panipat) and Tier 3 (Mumbai, Bengaluru, Hyderabad, Pune, Chennai, Kolkata, Ahmedabad). Basis: 9 of 11 admitted students with a known home came from North India, none from the far metros (small sample). Suggest the next tier only when Tier 1 brings at least 6 CRM enquiries from 300 clicks, or cannot spend its budget.\n'
  '- Keywords: use pilot, CPL and DGCA ground class phrases. The owner paused the general "aviation" and "flight" phrases; do not re-add them. In the last 365 days Rs 3,372 (132 clicks) went to non-pilot searches (BBA aviation, air hostess, ground staff) and Rs 7,822 to other institutes'' names.\n'
  '- Old conversion numbers are not enquiries: 89 of 204 "conversions" in 365 days came from non-pilot searches with more conversions than clicks (Google-hosted local actions). Judge results only by CRM enquiries.\n'
  '- Price: the Rs 20 click limit cut the average click from about Rs 35 (365 days) to about Rs 15. Keep it unless CRM enquiry data says otherwise.\n'
  '- Time of day (56 clicks, 13-15 Nov): 2pm-6pm was cheapest (Rs 11.6 a click), 6pm-10pm dearest (Rs 16.7) but brought half of all clicks and the most real enquiries (11 of 35). Too little data to switch hours off. The owner approved bids 30% lower from midnight to 6am only. Review each time slot by cost per CRM enquiry after 300 clicks.\n'
  '- Competitors: Top Crew Aviation runs 84 Google ads in India (62 Search) built on scholarship, placement and success-rate claims, with fee and eligibility sitelinks. Golden Epaulettes (Dwarka Sector 7) runs none and wins free search with city pages, mock tests and downloads. Use the eligibility and fees hooks; never copy the claims.\n'
  '- The biggest loss is after the click: median 48 hours to the first call for real website enquiries since September, and 30% of website forms since August were bots. When results are weak, say this before proposing more ad changes.'
 WHERE key = 'google_brand_facts' AND value NOT LIKE '%Verified research (25 Nov 2026%';

-- ---------------------------------------------------------------- schedule (same job, one more kind)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-google-build';
    PERFORM cron.schedule('crm-ads-google-build', '*/5 * * * *', $job$
      SELECT net.http_post(url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-google-ops',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{}'::jsonb, timeout_milliseconds := 140000)
      WHERE EXISTS (SELECT 1 FROM public.ads_google_ops WHERE kind IN ('campaign_create', 'income_filter', 'ad_schedule') AND status IN ('approved', 'executing')) $job$);
  END IF;
END $$;
