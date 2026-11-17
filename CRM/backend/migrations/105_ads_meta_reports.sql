-- 105: Meta Ads > Reports and account health. Run after 104. Re-runnable. Rollback: 105_ads_meta_reports_down.sql.
--
--  * Reports: Ads Manager-style reporting (levels, date presets, compare, breakdowns by time / demographics / geography /
--    delivery, filters, column presets and custom columns, saved views, CSV). Numbers are read live from Meta's Insights
--    API by ads-sync (job meta_report) and cached here (3 hours for recent days, 7 days for old ones), so they always match
--    Ads Manager and the CRM stores no copy of every split. CRM results (leads, qualified, admitted) are joined per
--    campaign / ad set / ad.
--  * Health (ads-sync job meta_health, every 3 hours): Meta's Opportunity Score and recommendations, account status and
--    spending limit, ads rejected or with issues, learning limited, spend today against daily budgets; warnings for
--    those and for no leads in a day, cost per lead up, spend jumps, a silent webhook and leads that failed to file.
--    New high warnings go to Admin and approvers (phone notification, and email when CRM email is set up).
--  * Agents helper: svc_ads_agents_meta_waiting() lets ads-agents tell an older helper to update itself.

CREATE TABLE IF NOT EXISTS public.ads_meta_report_cache (
  key text PRIMARY KEY,
  params jsonb NOT NULL,
  data jsonb NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL);
ALTER TABLE public.ads_meta_report_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_report_cache FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_report_view (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  params jsonb NOT NULL,           -- {report: {...}, ui: {preset, columns[], sort, filters{}}}
  owner uuid,
  shared boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ads_meta_report_view ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_report_view FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_report_view_id_seq FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_health (
  taken_at timestamptz PRIMARY KEY DEFAULT now(),
  data jsonb NOT NULL);
ALTER TABLE public.ads_meta_health ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_health FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.ads_meta_warning (
  id bigserial PRIMARY KEY,
  kind text NOT NULL,
  entity text NOT NULL DEFAULT 'account',
  severity text NOT NULL CHECK (severity IN ('high', 'medium', 'low')),
  title text NOT NULL,
  detail text,
  data jsonb NOT NULL DEFAULT '{}',
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  notified_at timestamptz,
  dismissed_by uuid, dismissed_at timestamptz);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ads_meta_warning_open ON public.ads_meta_warning (kind, entity) WHERE resolved_at IS NULL;
ALTER TABLE public.ads_meta_warning ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_warning FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ads_meta_warning_id_seq FROM anon, authenticated;

-- ------------------------------------------------------------------------------------------- agents helper
CREATE OR REPLACE FUNCTION public.svc_ads_agents_meta_waiting() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.ads_agent_runs WHERE status = 'queued' AND role LIKE 'meta\_%') $$;

-- ------------------------------------------------------------------------------------------- reports
CREATE OR REPLACE FUNCTION public.svc_ads_meta_report_cache_get(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT data || jsonb_build_object('fetched_at', fetched_at, 'cached', true) FROM public.ads_meta_report_cache
   WHERE key = p_key AND expires_at > now() $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_report_cache_put(p_key text, p_params jsonb, p_data jsonb, p_hours int) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM public.ads_meta_report_cache WHERE expires_at < now() - interval '1 day';
  INSERT INTO public.ads_meta_report_cache (key, params, data, fetched_at, expires_at)
  VALUES (p_key, p_params, p_data, now(), now() + make_interval(hours => greatest(1, least(p_hours, 24 * 7))))
  ON CONFLICT (key) DO UPDATE SET params = EXCLUDED.params, data = EXCLUDED.data, fetched_at = now(), expires_at = EXCLUDED.expires_at;
$$;

-- The account Reports and Health read (service role).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_report_account() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN a.id IS NOT NULL THEN jsonb_build_object('id', a.external_id, 'currency', a.currency) END FROM (SELECT (crm_private.ads_meta_acct()).*) a $$;

-- What the Reports filters can offer: the account's campaigns, ad sets, ads and forms, and saved views.
CREATE OR REPLACE FUNCTION public.api_ads_meta_report_options() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE acc public.ads_accounts := crm_private.ads_meta_acct(); me uuid := crm_private.current_employee_id();
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'account', CASE WHEN acc.id IS NOT NULL THEN jsonb_build_object('id', acc.external_id, 'name', acc.name, 'currency', acc.currency, 'timezone', acc.timezone) END,
    'today', crm_private.ads_meta_today(),
    'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.external_id, 'name', o.name, 'status', o.status) ORDER BY o.created_time DESC NULLS LAST), '[]')
                    FROM public.ads_meta_object o WHERE o.level = 'campaign'),
    'adsets', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.external_id, 'name', o.name, 'status', o.status, 'campaign', o.campaign_ext) ORDER BY o.created_time DESC NULLS LAST), '[]')
                 FROM public.ads_meta_object o WHERE o.level = 'adset'),
    'ads', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.external_id, 'name', o.name, 'status', o.status, 'campaign', o.campaign_ext, 'adset', o.adset_ext,
              'format', o.info->>'format', 'form_id', o.info->>'form_id') ORDER BY o.created_time DESC NULLS LAST), '[]')
              FROM public.ads_meta_object o WHERE o.level = 'ad'),
    'forms', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.form_id, 'name', f.name)), '[]') FROM public.ads_meta_forms f),
    'views', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'params', v.params, 'shared', v.shared, 'mine', v.owner = me) ORDER BY v.name), '[]')
                FROM public.ads_meta_report_view v WHERE v.owner = me OR v.shared),
    'can_admin', crm_private.is_admin());
END $$;

-- CRM results per campaign / ad set / ad for a period (keyed by Meta id).
CREATE OR REPLACE FUNCTION public.api_ads_meta_report_crm(p_from date, p_to date, p_level text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_level NOT IN ('account', 'campaign', 'adset', 'ad') THEN RAISE EXCEPTION 'Unknown level' USING ERRCODE = 'PT422'; END IF;
  IF p_to - p_from > 1200 THEN RAISE EXCEPTION 'Period too long' USING ERRCODE = 'PT422'; END IF;
  RETURN (SELECT coalesce(jsonb_object_agg(k, jsonb_build_object('crm', n, 'qualified', q, 'customers', c)), '{}') FROM (
    SELECT CASE p_level WHEN 'ad' THEN x.ad_ext WHEN 'adset' THEN x.adset_ext WHEN 'campaign' THEN x.campaign_ext ELSE 'account' END k,
           count(*) n, count(*) FILTER (WHERE x.qualified) q, count(*) FILTER (WHERE x.customer) c
      FROM crm_private.ads_meta_crm(p_from, p_to, NULL, NULL, NULL) x GROUP BY 1) z WHERE k IS NOT NULL);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_report_view_save(p_id bigint, p_name text, p_params jsonb, p_shared boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me uuid := crm_private.current_employee_id(); v public.ads_meta_report_view; nm text := left(btrim(coalesce(p_name, '')), 60);
BEGIN
  PERFORM crm_private.ads_require_view();
  IF nm = '' THEN RAISE EXCEPTION 'Give the view a name' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_typeof(p_params) <> 'object' OR length(p_params::text) > 20000 THEN RAISE EXCEPTION 'View settings are not valid' USING ERRCODE = 'PT422'; END IF;
  IF coalesce(p_shared, false) AND NOT crm_private.is_admin() THEN RAISE EXCEPTION 'Only Admin shares views with everyone' USING ERRCODE = 'PT403'; END IF;
  IF p_id IS NULL THEN
    IF (SELECT count(*) FROM public.ads_meta_report_view WHERE owner = me) >= 50 THEN RAISE EXCEPTION 'You have 50 saved views; delete one first' USING ERRCODE = 'PT422'; END IF;
    INSERT INTO public.ads_meta_report_view (name, params, owner, shared) VALUES (nm, p_params, me, coalesce(p_shared, false)) RETURNING * INTO v;
  ELSE
    UPDATE public.ads_meta_report_view SET name = nm, params = p_params, shared = coalesce(p_shared, false), updated_at = now()
     WHERE id = p_id AND (owner = me OR crm_private.is_admin()) RETURNING * INTO v;
    IF v.id IS NULL THEN RAISE EXCEPTION 'View not found' USING ERRCODE = 'PT404'; END IF;
  END IF;
  RETURN jsonb_build_object('id', v.id, 'name', v.name);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_report_view_delete(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  DELETE FROM public.ads_meta_report_view WHERE id = p_id AND (owner = crm_private.current_employee_id() OR crm_private.is_admin());
  IF NOT FOUND THEN RAISE EXCEPTION 'View not found' USING ERRCODE = 'PT404'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ------------------------------------------------------------------------------------------- health and warnings
-- Saves a health check and its warnings: new ones open, seen ones stay, missing ones close. Adds the CRM's own checks
-- (silent webhook, leads that failed to file). Returns new high warnings to notify, with who to tell.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_health_save(p_data jsonb, p_warnings jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w jsonb := coalesce(p_warnings, '[]'); x jsonb; seen text[] := '{}'; got int; failed int; meta_y int; out jsonb; rcp uuid[];
BEGIN
  INSERT INTO public.ads_meta_health (taken_at, data) VALUES (now(), coalesce(p_data, '{}'));
  DELETE FROM public.ads_meta_health WHERE taken_at < now() - interval '30 days';
  -- the CRM's own checks
  meta_y := coalesce((p_data->'yesterday'->>'leads')::int, 0);
  SELECT count(*) INTO got FROM public.ads_meta_lead_raw
   WHERE source = 'instant_form' AND coalesce(created_time, received_at) >= ((crm_private.ads_meta_today() - 1)::timestamp AT TIME ZONE 'Asia/Kolkata')
     AND coalesce(created_time, received_at) < (crm_private.ads_meta_today()::timestamp AT TIME ZONE 'Asia/Kolkata') AND ad_id IS NOT NULL;
  IF meta_y > got + 1 THEN
    w := w || jsonb_build_array(jsonb_build_object('kind', 'webhook_silent', 'entity', 'account', 'severity', 'high',
      'title', 'Meta counted more leads than the CRM received',
      'detail', format('Meta counted %s lead(s) yesterday; the CRM received %s. Check Meta Ads > Setup (webhook and Page access).', meta_y, got)));
  END IF;
  SELECT count(*) INTO failed FROM public.ads_meta_lead_raw WHERE status = 'failed' AND coalesce(last_try_at, received_at) > now() - interval '24 hours';
  IF failed > 0 THEN
    w := w || jsonb_build_array(jsonb_build_object('kind', 'lead_errors', 'entity', 'account', 'severity', 'high',
      'title', format('%s lead(s) could not be filed', failed), 'detail', 'See Meta Ads > Setup step 8 for the reason; the CRM keeps retrying.'));
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(w) LOOP
    CONTINUE WHEN coalesce(x->>'kind', '') = '' OR coalesce(x->>'severity', '') NOT IN ('high', 'medium', 'low');
    seen := seen || (x->>'kind' || '|' || coalesce(x->>'entity', 'account'));
    INSERT INTO public.ads_meta_warning (kind, entity, severity, title, detail, data)
    VALUES (x->>'kind', coalesce(x->>'entity', 'account'), x->>'severity', left(x->>'title', 200), left(x->>'detail', 1000), coalesce(x->'data', '{}'))
    ON CONFLICT (kind, entity) WHERE resolved_at IS NULL
    DO UPDATE SET last_seen = now(), severity = EXCLUDED.severity, title = EXCLUDED.title, detail = EXCLUDED.detail, data = EXCLUDED.data;
  END LOOP;
  UPDATE public.ads_meta_warning SET resolved_at = now() WHERE resolved_at IS NULL AND NOT ((kind || '|' || entity) = ANY (seen));
  SELECT coalesce(array_agg(DISTINCT e.id), '{}') INTO rcp FROM public.employee e
   WHERE e.active AND (e.department::text = 'Admin' OR EXISTS (SELECT 1 FROM public.ads_access a WHERE a.employee_id = e.id AND a.can_approve));
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail, 'kind', a.kind)), '[]') INTO out
    FROM public.ads_meta_warning a WHERE a.resolved_at IS NULL AND a.dismissed_at IS NULL AND a.notified_at IS NULL AND a.severity = 'high';
  RETURN jsonb_build_object('notify', out,
    'emails', (SELECT coalesce(jsonb_agg(DISTINCT e.email), '[]') FROM public.employee e WHERE e.id = ANY (rcp) AND e.email ~ '@'),
    'subs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))), '[]')
               FROM public.amazon_push_subs s WHERE s.employee_id = ANY (rcp)),
    'vapid_keys', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_vapid_keys'),
    'mail', public.svc_ads_meta_mail_config() - 'to');
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_warnings_notified(p_ids bigint[]) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.ads_meta_warning SET notified_at = now() WHERE id = ANY (p_ids) $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_health() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'latest', (SELECT jsonb_build_object('taken_at', h.taken_at, 'data', h.data) FROM public.ads_meta_health h ORDER BY h.taken_at DESC LIMIT 1),
    'score_trend', (SELECT coalesce(jsonb_agg(jsonb_build_object('at', z.taken_at, 'score', z.score) ORDER BY z.taken_at), '[]') FROM (
        SELECT DISTINCT ON (h.taken_at::date) h.taken_at, (h.data->'opportunity'->>'score')::numeric score FROM public.ads_meta_health h
         WHERE h.data->'opportunity'->>'score' IS NOT NULL ORDER BY h.taken_at::date, h.taken_at DESC) z),
    'warnings', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'entity', a.entity, 'severity', a.severity, 'title', a.title,
        'detail', a.detail, 'data', a.data, 'first_seen', a.first_seen, 'last_seen', a.last_seen, 'dismissed', a.dismissed_at IS NOT NULL)
        ORDER BY (a.severity = 'high') DESC, a.first_seen DESC), '[]') FROM public.ads_meta_warning a WHERE a.resolved_at IS NULL),
    'resolved_7d', (SELECT count(*) FROM public.ads_meta_warning WHERE resolved_at > now() - interval '7 days'));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_warning_dismiss(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  UPDATE public.ads_meta_warning SET dismissed_at = now(), dismissed_by = crm_private.current_employee_id() WHERE id = p_id AND resolved_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Warning not found' USING ERRCODE = 'PT404'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ------------------------------------------------------------------------------------------- grants, version, schedule
REVOKE ALL ON FUNCTION public.api_ads_meta_report_options(), public.api_ads_meta_report_crm(date, date, text),
  public.api_ads_meta_report_view_save(bigint, text, jsonb, boolean), public.api_ads_meta_report_view_delete(bigint),
  public.api_ads_meta_health(), public.api_ads_meta_warning_dismiss(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_report_options(), public.api_ads_meta_report_crm(date, date, text),
  public.api_ads_meta_report_view_save(bigint, text, jsonb, boolean), public.api_ads_meta_report_view_delete(bigint),
  public.api_ads_meta_health(), public.api_ads_meta_warning_dismiss(bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_ads_agents_meta_waiting(), public.svc_ads_meta_report_account(), public.svc_ads_meta_report_cache_get(text),
  public.svc_ads_meta_report_cache_put(text, jsonb, jsonb, int), public.svc_ads_meta_health_save(jsonb, jsonb),
  public.svc_ads_meta_warnings_notified(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_agents_meta_waiting(), public.svc_ads_meta_report_account(), public.svc_ads_meta_report_cache_get(text),
  public.svc_ads_meta_report_cache_put(text, jsonb, jsonb, int), public.svc_ads_meta_health_save(jsonb, jsonb),
  public.svc_ads_meta_warnings_notified(bigint[]) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '105')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-health';
    PERFORM cron.schedule('crm-ads-meta-health', '40 */3 * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_health"]}'::jsonb, timeout_milliseconds := 120000)
      WHERE (crm_private.ads_meta_acct()).id IS NOT NULL
    $job$);
  END IF;
END $$;
