-- 103: Meta Ads > Insights (read-only history, patterns and a monthly summary). Needs 102. Safe to run again.
--
-- What it stores (filled by ads-sync job meta_history; it never changes an ad):
--   ads_meta_object     campaigns, ad sets (targeting summary) and ads (creative: format, headline, text, call to action,
--                       thumbnail, lead form). Names also come from the numbers, so deleted ads keep their name.
--   ads_meta_ad_day     one row per ad per day: spend, impressions, clicks, link clicks, Meta-counted leads, video views.
--                       Back-filled once for up to 37 months (Meta keeps totals for 37 months), then the last 30 days
--                       are refreshed daily. Campaign and ad set totals are sums of their ads.
--   ads_meta_breakdown  whole-account monthly numbers by age x gender, region, placement, device and hour of day for the
--                       last 13 months, and by how often people saw the ads for the last 6 months (Meta's limits).
--   ads_meta_note       notes on the timeline (exam dates, offers, price changes).
--   ads_meta_report     the saved summary of each month (built on the 1st, emailed when CRM email is set up).
-- CRM outcomes come from Ads leads (crm_private.ads_ad_leads, 098): each Meta lead carries the ad / ad set / campaign /
-- form it came from, and its stage says if it qualified or was admitted (booking confirmed for Charter).
-- Undo: 103_ads_meta_insights_down.sql.

CREATE TABLE IF NOT EXISTS public.ads_meta_object (
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  level text NOT NULL CHECK (level IN ('campaign', 'adset', 'ad')),
  external_id text NOT NULL CHECK (external_id ~ '^[0-9]{3,25}$'),
  campaign_ext text, adset_ext text,
  name text, status text, created_time timestamptz,
  info jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (level, external_id));
CREATE INDEX IF NOT EXISTS idx_ads_meta_object_account ON public.ads_meta_object (account_id, level);

CREATE TABLE IF NOT EXISTS public.ads_meta_ad_day (
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  ad_ext text NOT NULL, adset_ext text, campaign_ext text,
  day date NOT NULL,
  spend numeric(14,2) NOT NULL DEFAULT 0, impressions bigint NOT NULL DEFAULT 0, clicks bigint NOT NULL DEFAULT 0,
  link_clicks bigint, leads int NOT NULL DEFAULT 0, video_views bigint, frequency numeric(8,3),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ad_ext, day));
CREATE INDEX IF NOT EXISTS idx_ads_meta_ad_day_day ON public.ads_meta_ad_day (account_id, day);
CREATE INDEX IF NOT EXISTS idx_ads_meta_ad_day_campaign ON public.ads_meta_ad_day (campaign_ext, day);

CREATE TABLE IF NOT EXISTS public.ads_meta_breakdown (
  account_id uuid NOT NULL REFERENCES public.ads_accounts(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('age_gender', 'region', 'placement', 'device', 'hour', 'frequency')),
  month date NOT NULL, k1 text NOT NULL, k2 text NOT NULL DEFAULT '',
  spend numeric(14,2) NOT NULL DEFAULT 0, impressions bigint NOT NULL DEFAULT 0, clicks bigint NOT NULL DEFAULT 0,
  leads int NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, kind, month, k1, k2));

CREATE TABLE IF NOT EXISTS public.ads_meta_note (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  text text NOT NULL CHECK (length(btrim(text)) BETWEEN 1 AND 200),
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS public.ads_meta_report (
  month date PRIMARY KEY CHECK (month = date_trunc('month', month)::date),
  data jsonb NOT NULL, patterns jsonb NOT NULL DEFAULT '[]',
  created_at timestamptz NOT NULL DEFAULT now(), emailed_at timestamptz, email_error text);

ALTER TABLE public.ads_meta_object ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_meta_ad_day ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_meta_breakdown ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_meta_note ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_meta_report ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_object, public.ads_meta_ad_day, public.ads_meta_breakdown, public.ads_meta_note, public.ads_meta_report
  FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES
  ('meta_history_months', '37'),          -- how far back the one-time back-fill goes (Meta keeps 37 months of totals)
  ('meta_history_cursor', ''),            -- first day of the next month to back-fill ('' = not started)
  ('meta_history_done_at', ''), ('meta_history_recent_at', ''), ('meta_history_breakdowns_at', ''),
  ('meta_report_emails', '[]')            -- who gets the monthly summary (JSON list of addresses)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------------------------------------ reading helpers
-- One account's day of reporting, ad rows, filtered by campaign / lead form.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_days(p_from date, p_to date, p_campaign text, p_form text)
RETURNS SETOF public.ads_meta_ad_day
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT d.* FROM public.ads_meta_ad_day d
   WHERE d.day BETWEEN p_from AND p_to
     AND (p_campaign IS NULL OR d.campaign_ext = p_campaign)
     AND (p_form IS NULL OR EXISTS (SELECT 1 FROM public.ads_meta_object o
                                     WHERE o.level = 'ad' AND o.external_id = d.ad_ext AND o.info->>'form_id' = p_form)) $$;

-- Meta Ads leads in the CRM with the ad / ad set / campaign / form they came from and how far they got.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_crm(p_from date, p_to date, p_campaign text, p_form text, p_pipeline text)
RETURNS TABLE (lead_id uuid, day date, ad_ext text, adset_ext text, campaign_ext text, form_id text, qualified boolean, customer boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT * FROM (
    SELECT x.lead_id, (x.created_at AT TIME ZONE coalesce(a.timezone, 'Asia/Kolkata'))::date AS day,
           crm_private.ads_touch_num(x.touch, 'ad_id', 'fb_ad_id', 'utm_content') AS ad_ext,
           crm_private.ads_touch_num(x.touch, 'adset_id', 'fb_adset_id', 'utm_term') AS adset_ext,
           coalesce(crm_private.ads_touch_num(x.touch, 'utm_campaignid', 'campaign_id', 'fb_campaign_id', 'utm_id'), c.external_id) AS campaign_ext,
           x.touch->>'form_id' AS form_id, x.qualified, x.customer
      FROM crm_private.ads_ad_leads() x
      JOIN public.ads_lead l ON l.id = x.lead_id
      LEFT JOIN public.ads_campaigns c ON c.id = x.campaign_id
      LEFT JOIN public.ads_accounts a ON a.id = x.account_id
     WHERE x.platform = 'meta' AND (p_pipeline IS NULL OR l.pipeline = p_pipeline)) z
   WHERE z.day BETWEEN p_from AND p_to
     AND (p_campaign IS NULL OR z.campaign_ext = p_campaign)
     AND (p_form IS NULL OR z.form_id = p_form
          OR EXISTS (SELECT 1 FROM public.ads_meta_object o WHERE o.level = 'ad' AND o.external_id = z.ad_ext AND o.info->>'form_id' = p_form)) $$;

-- Totals of a period: Meta's numbers and the CRM's.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_totals(p_from date, p_to date, p_campaign text, p_form text, p_pipeline text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'spend', coalesce((SELECT sum(spend) FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)), 0),
    'impressions', coalesce((SELECT sum(impressions) FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)), 0),
    'clicks', coalesce((SELECT sum(clicks) FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)), 0),
    'link_clicks', coalesce((SELECT sum(link_clicks) FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)), 0),
    'meta_leads', coalesce((SELECT sum(leads) FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)), 0))
  || (SELECT jsonb_build_object('crm_leads', count(*), 'qualified', count(*) FILTER (WHERE qualified),
             'customers', count(*) FILTER (WHERE customer))
        FROM crm_private.ads_meta_crm(p_from, p_to, p_campaign, p_form, p_pipeline)) $$;

-- Everything Meta Ads > Insights shows for a period. Patterns, what-if and charts are worked out from this in the
-- browser (supabase/functions/_shared/meta_patterns.ts, also used for the monthly summary).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_insights_data(p_from date, p_to date, p_campaign text, p_form text, p_pipeline text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE len int := p_to - p_from + 1; out jsonb;
BEGIN
  WITH d AS (SELECT * FROM crm_private.ads_meta_days(p_from, p_to, p_campaign, p_form)),
  c AS (SELECT * FROM crm_private.ads_meta_crm(p_from, p_to, p_campaign, p_form, p_pipeline)),
  -- weekly trend (weeks start Monday)
  tw AS (SELECT date_trunc('week', day)::date wk, sum(spend) spend, sum(impressions) impressions, sum(clicks) clicks, sum(leads) meta_leads
           FROM d GROUP BY 1),
  tc AS (SELECT date_trunc('week', day)::date wk, count(*) crm_leads, count(*) FILTER (WHERE qualified) qualified,
                count(*) FILTER (WHERE customer) customers FROM c GROUP BY 1),
  -- per weekday
  wd AS (SELECT extract(isodow FROM day)::int dow, sum(spend) spend, sum(leads) meta_leads, sum(clicks) clicks, sum(impressions) impressions
           FROM d GROUP BY 1),
  -- leaderboards
  bc AS (SELECT campaign_ext ext, sum(spend) spend, sum(impressions) impressions, sum(clicks) clicks, sum(leads) meta_leads,
                min(day) first_day, max(day) last_day FROM d WHERE campaign_ext IS NOT NULL GROUP BY 1),
  ba AS (SELECT adset_ext ext, max(campaign_ext) campaign_ext, sum(spend) spend, sum(impressions) impressions, sum(clicks) clicks,
                sum(leads) meta_leads, min(day) first_day, max(day) last_day FROM d WHERE adset_ext IS NOT NULL GROUP BY 1),
  bd AS (SELECT ad_ext ext, max(adset_ext) adset_ext, max(campaign_ext) campaign_ext, sum(spend) spend, sum(impressions) impressions,
                sum(clicks) clicks, sum(link_clicks) link_clicks, sum(leads) meta_leads, sum(video_views) video_views,
                min(day) first_day, max(day) last_day, count(*) days FROM d GROUP BY 1),
  cc AS (SELECT campaign_ext ext, count(*) crm_leads, count(*) FILTER (WHERE qualified) qualified, count(*) FILTER (WHERE customer) customers
           FROM c WHERE campaign_ext IS NOT NULL GROUP BY 1),
  ca AS (SELECT adset_ext ext, count(*) crm_leads, count(*) FILTER (WHERE qualified) qualified, count(*) FILTER (WHERE customer) customers
           FROM c WHERE adset_ext IS NOT NULL GROUP BY 1),
  cd AS (SELECT ad_ext ext, count(*) crm_leads, count(*) FILTER (WHERE qualified) qualified, count(*) FILTER (WHERE customer) customers
           FROM c WHERE ad_ext IS NOT NULL GROUP BY 1),
  -- ad fatigue: click rate in each week of an ad's life against its first week (ads with 4+ weeks of data)
  life AS (SELECT a.ad_ext, a.day, a.impressions, a.clicks, a.spend, a.leads, min(a.day) OVER (PARTITION BY a.ad_ext) start_day
             FROM public.ads_meta_ad_day a WHERE a.ad_ext IN (SELECT ext FROM bd)),
  lw AS (SELECT ad_ext, (day - start_day) / 7 + 1 w, sum(impressions) i, sum(clicks) k, sum(spend) s, sum(leads) l FROM life GROUP BY 1, 2),
  lb AS (SELECT ad_ext, k::numeric / i ctr1 FROM lw WHERE w = 1 AND i >= 500 AND k > 0
           AND ad_ext IN (SELECT ad_ext FROM lw GROUP BY 1 HAVING max(w) >= 4)),
  curve AS (SELECT lw.w, round(avg((lw.k::numeric / lw.i) / lb.ctr1), 3) ctr_index, count(*) ads, sum(lw.s) spend, sum(lw.l) leads
              FROM lw JOIN lb USING (ad_ext) WHERE lw.w <= 12 AND lw.i >= 200 GROUP BY 1)
  SELECT jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'days', len, 'prev_from', p_from - len, 'prev_to', p_from - 1),
    'filters', jsonb_build_object('campaign', p_campaign, 'form', p_form, 'pipeline', p_pipeline),
    'current', crm_private.ads_meta_totals(p_from, p_to, p_campaign, p_form, p_pipeline),
    'previous', crm_private.ads_meta_totals(p_from - len, p_from - 1, p_campaign, p_form, p_pipeline),
    'trend', coalesce((SELECT jsonb_agg(jsonb_build_object('week', coalesce(tw.wk, tc.wk), 'spend', coalesce(tw.spend, 0),
                  'impressions', coalesce(tw.impressions, 0), 'clicks', coalesce(tw.clicks, 0), 'meta_leads', coalesce(tw.meta_leads, 0),
                  'crm_leads', coalesce(tc.crm_leads, 0), 'qualified', coalesce(tc.qualified, 0), 'customers', coalesce(tc.customers, 0))
                  ORDER BY coalesce(tw.wk, tc.wk)) FROM tw FULL JOIN tc ON tc.wk = tw.wk), '[]'),
    'weekday', coalesce((SELECT jsonb_agg(to_jsonb(wd) ORDER BY wd.dow) FROM wd), '[]'),
    'board', jsonb_build_object(
      'campaign', coalesce((SELECT jsonb_agg(jsonb_build_object('ext', bc.ext, 'name', coalesce(o.name, bc.ext), 'status', o.status,
                    'spend', bc.spend, 'impressions', bc.impressions, 'clicks', bc.clicks, 'meta_leads', bc.meta_leads,
                    'crm_leads', coalesce(cc.crm_leads, 0), 'qualified', coalesce(cc.qualified, 0), 'customers', coalesce(cc.customers, 0),
                    'first_day', bc.first_day, 'last_day', bc.last_day, 'objective', o.info->>'objective') ORDER BY bc.spend DESC)
                    FROM bc LEFT JOIN cc ON cc.ext = bc.ext
                    LEFT JOIN public.ads_meta_object o ON o.level = 'campaign' AND o.external_id = bc.ext), '[]'),
      'adset', coalesce((SELECT jsonb_agg(x ORDER BY (x->>'spend')::numeric DESC) FROM (
                    SELECT jsonb_build_object('ext', ba.ext, 'campaign_ext', ba.campaign_ext, 'name', coalesce(o.name, ba.ext), 'status', o.status,
                    'spend', ba.spend, 'impressions', ba.impressions, 'clicks', ba.clicks, 'meta_leads', ba.meta_leads,
                    'crm_leads', coalesce(ca.crm_leads, 0), 'qualified', coalesce(ca.qualified, 0), 'customers', coalesce(ca.customers, 0),
                    'first_day', ba.first_day, 'last_day', ba.last_day, 'info', coalesce(o.info, '{}')) x
                    FROM ba LEFT JOIN ca ON ca.ext = ba.ext
                    LEFT JOIN public.ads_meta_object o ON o.level = 'adset' AND o.external_id = ba.ext
                    ORDER BY ba.spend DESC LIMIT 150) s), '[]'),
      'ad', coalesce((SELECT jsonb_agg(x ORDER BY (x->>'spend')::numeric DESC) FROM (
                    SELECT jsonb_build_object('ext', bd.ext, 'adset_ext', bd.adset_ext, 'campaign_ext', bd.campaign_ext,
                    'name', coalesce(o.name, bd.ext), 'status', o.status,
                    'spend', bd.spend, 'impressions', bd.impressions, 'clicks', bd.clicks, 'link_clicks', bd.link_clicks,
                    'meta_leads', bd.meta_leads, 'video_views', bd.video_views, 'days', bd.days,
                    'crm_leads', coalesce(cd.crm_leads, 0), 'qualified', coalesce(cd.qualified, 0), 'customers', coalesce(cd.customers, 0),
                    'first_day', bd.first_day, 'last_day', bd.last_day, 'info', coalesce(o.info, '{}')) x
                    FROM bd LEFT JOIN cd ON cd.ext = bd.ext
                    LEFT JOIN public.ads_meta_object o ON o.level = 'ad' AND o.external_id = bd.ext
                    ORDER BY bd.spend DESC LIMIT 300) s), '[]')),
    -- CRM leads whose ad is not known (website leads without ad ids, older leads): counted in the totals only
    'crm_unplaced', (SELECT count(*) FROM c WHERE c.ad_ext IS NULL),
    'breakdowns', coalesce((SELECT jsonb_object_agg(kind, rows) FROM (
                    SELECT b.kind, jsonb_agg(jsonb_build_object('k1', b.k1, 'k2', b.k2, 'spend', b.spend, 'impressions', b.impressions,
                           'clicks', b.clicks, 'leads', b.leads) ORDER BY b.spend DESC) rows
                      FROM (SELECT kind, k1, k2, sum(spend) spend, sum(impressions) impressions, sum(clicks) clicks, sum(leads) leads
                              FROM public.ads_meta_breakdown
                             WHERE month BETWEEN date_trunc('month', p_from)::date AND p_to GROUP BY 1, 2, 3) b
                     GROUP BY b.kind) k), '{}'),
    'breakdown_months', (SELECT jsonb_build_object('from', min(month), 'to', max(month)) FROM public.ads_meta_breakdown),
    'fatigue', coalesce((SELECT jsonb_agg(jsonb_build_object('week', w, 'ctr_index', ctr_index, 'ads', ads, 'spend', spend, 'leads', leads)
                    ORDER BY w) FROM curve), '[]'),
    'notes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', n.id, 'day', n.day, 'text', n.text) ORDER BY n.day)
                    FROM public.ads_meta_note n WHERE n.day BETWEEN p_from AND p_to), '[]'),
    'options', jsonb_build_object(
      'campaigns', coalesce((SELECT jsonb_agg(jsonb_build_object('ext', o.external_id, 'name', o.name) ORDER BY o.name)
                    FROM public.ads_meta_object o WHERE o.level = 'campaign'), '[]'),
      'forms', coalesce((SELECT jsonb_agg(jsonb_build_object('id', f.form_id, 'name', f.name) ORDER BY f.name)
                    FROM public.ads_meta_forms f), '[]')),
    'coverage', jsonb_build_object(
      'first_day', (SELECT min(day) FROM public.ads_meta_ad_day), 'last_day', (SELECT max(day) FROM public.ads_meta_ad_day),
      'ads', (SELECT count(*) FROM public.ads_meta_object WHERE level = 'ad'),
      'months', crm_private.ads_cfg('meta_history_months')::int,
      'cursor', nullif(crm_private.ads_cfg('meta_history_cursor'), ''),
      'done_at', nullif(crm_private.ads_cfg('meta_history_done_at'), ''),
      'recent_at', nullif(crm_private.ads_cfg('meta_history_recent_at'), ''),
      'breakdowns_at', nullif(crm_private.ads_cfg('meta_history_breakdowns_at'), ''),
      'last_run', (SELECT jsonb_build_object('status', r.status, 'detail', r.detail, 'at', r.started_at)
                     FROM public.ads_sync_runs r WHERE r.job = 'meta_history' ORDER BY r.started_at DESC LIMIT 1)))
  INTO out;
  RETURN out;
END $$;

-- ------------------------------------------------------------------------------------------------ dashboard API
CREATE OR REPLACE FUNCTION public.api_ads_meta_insights(p_from date, p_to date, p_campaign text DEFAULT NULL,
  p_form text DEFAULT NULL, p_pipeline text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 1200 THEN
    RAISE EXCEPTION 'Pick a period of 1 day to about 3 years' USING ERRCODE = 'PT422';
  END IF;
  IF p_pipeline IS NOT NULL AND p_pipeline NOT IN ('pilot_training', 'charter') THEN
    RAISE EXCEPTION 'Unknown pipeline' USING ERRCODE = 'PT422';
  END IF;
  RETURN crm_private.ads_meta_insights_data(p_from, p_to, nullif(p_campaign, ''), nullif(p_form, ''), p_pipeline);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_note_save(p_day date, p_text text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nid bigint;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p_day IS NULL OR length(btrim(coalesce(p_text, ''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'A note needs a date and 1 to 200 characters' USING ERRCODE = 'PT422';
  END IF;
  INSERT INTO public.ads_meta_note (day, text, created_by) VALUES (p_day, btrim(p_text), auth.uid()) RETURNING id INTO nid;
  RETURN nid;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_note_delete(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  DELETE FROM public.ads_meta_note WHERE id = p_id;
END $$;

-- Saved monthly summaries (newest first) and who gets them by email.
CREATE OR REPLACE FUNCTION public.api_ads_meta_reports() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object(
    'reports', coalesce((SELECT jsonb_agg(jsonb_build_object('month', r.month, 'current', r.data->'current', 'previous', r.data->'previous',
                 'patterns', r.patterns, 'created_at', r.created_at, 'emailed_at', r.emailed_at, 'email_error', r.email_error)
                 ORDER BY r.month DESC) FROM (SELECT * FROM public.ads_meta_report ORDER BY month DESC LIMIT 24) r), '[]'),
    'emails', coalesce(nullif(crm_private.ads_cfg('meta_report_emails'), ''), '[]')::jsonb,
    'email_ready', crm_private.ads_meta_mail_ready());
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_meta_report_emails_save(p_emails jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF jsonb_typeof(p_emails) IS DISTINCT FROM 'array' OR jsonb_array_length(p_emails) > 10
     OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_emails) e WHERE e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
    RAISE EXCEPTION 'Up to 10 valid email addresses' USING ERRCODE = 'PT422';
  END IF;
  INSERT INTO public.ads_config (key, value) VALUES ('meta_report_emails', p_emails::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
END $$;

-- ------------------------------------------------------------------------------------------------ ads-sync (service)
-- CRM email (the same SMTP set up for the CRM's alert emails) is ready when a server and password are saved.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_mail_ready() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF to_regclass('public.amazon_config') IS NULL THEN RETURN false; END IF;
  RETURN coalesce((SELECT (value::jsonb->>'host') IS NOT NULL FROM public.amazon_config WHERE key = 'smtp'), false)
     AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'crm_smtp_password');
END $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_mail_config() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_meta_mail_ready() THEN RETURN jsonb_build_object('ready', false); END IF;
  RETURN jsonb_build_object('ready', true,
    'smtp', (SELECT value::jsonb FROM public.amazon_config WHERE key = 'smtp'),
    'password', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_smtp_password'),
    'to', coalesce(nullif(crm_private.ads_cfg('meta_report_emails'), ''), '[]')::jsonb);
END $$;

-- What the history job should do now.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_history_plan() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE months int := greatest(1, least(37, coalesce(nullif(crm_private.ads_cfg('meta_history_months'), '')::int, 37)));
  cur text := nullif(crm_private.ads_cfg('meta_history_cursor'), '');
  start date := (date_trunc('month', current_date) - make_interval(months => months - 1))::date;
  prev_month date := (date_trunc('month', current_date) - interval '1 month')::date;
BEGIN
  RETURN jsonb_build_object(
    'accounts', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'external_id', a.external_id, 'timezone', a.timezone, 'currency', a.currency))
                  FROM public.ads_accounts a WHERE a.platform = 'meta' AND a.status = 'connected'), '[]'),
    'months', months, 'start', start,
    'cursor', coalesce(cur, start::text),
    'done', nullif(crm_private.ads_cfg('meta_history_done_at'), '') IS NOT NULL,
    'recent_due', coalesce(nullif(crm_private.ads_cfg('meta_history_recent_at'), '')::timestamptz < now() - interval '20 hours', true),
    'breakdowns_due', coalesce(nullif(crm_private.ads_cfg('meta_history_breakdowns_at'), '')::timestamptz < now() - interval '7 days', true),
    'report_month', CASE WHEN nullif(crm_private.ads_cfg('meta_history_done_at'), '') IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM public.ads_meta_report WHERE month = prev_month)
                          AND EXISTS (SELECT 1 FROM public.ads_meta_ad_day WHERE day BETWEEN prev_month AND (prev_month + interval '1 month - 1 day')::date)
                         THEN prev_month END);
END $$;

-- Campaigns / ad sets / ads. A row without info (a name from the numbers) never wipes info saved before.
CREATE OR REPLACE FUNCTION public.svc_ads_meta_objects_save(p_account uuid, p_items jsonb) RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH ins AS (
    INSERT INTO public.ads_meta_object AS o (account_id, level, external_id, campaign_ext, adset_ext, name, status, created_time, info, updated_at)
    SELECT DISTINCT ON (x->>'level', x->>'external_id') p_account, x->>'level', x->>'external_id', x->>'campaign_ext', x->>'adset_ext',
           left(x->>'name', 300), left(x->>'status', 40), (x->>'created_time')::timestamptz, coalesce(x->'info', '{}'), now()
      FROM jsonb_array_elements(p_items) x
     WHERE x->>'level' IN ('campaign', 'adset', 'ad') AND x->>'external_id' ~ '^[0-9]{3,25}$'
     ORDER BY x->>'level', x->>'external_id', (x->'info' <> '{}') DESC
    ON CONFLICT (level, external_id) DO UPDATE SET
      account_id = EXCLUDED.account_id,
      campaign_ext = coalesce(EXCLUDED.campaign_ext, o.campaign_ext), adset_ext = coalesce(EXCLUDED.adset_ext, o.adset_ext),
      name = coalesce(EXCLUDED.name, o.name), status = coalesce(EXCLUDED.status, o.status),
      created_time = coalesce(EXCLUDED.created_time, o.created_time),
      info = CASE WHEN EXCLUDED.info = '{}' THEN o.info ELSE EXCLUDED.info END, updated_at = now()
    RETURNING 1)
  SELECT count(*)::int FROM ins $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_ad_days_save(p_account uuid, p_items jsonb) RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  WITH ins AS (
    INSERT INTO public.ads_meta_ad_day AS d (account_id, ad_ext, adset_ext, campaign_ext, day, spend, impressions, clicks,
                                             link_clicks, leads, video_views, frequency, updated_at)
    SELECT DISTINCT ON (x->>'ad_ext', x->>'day') p_account, x->>'ad_ext', x->>'adset_ext', x->>'campaign_ext', (x->>'day')::date,
           coalesce((x->>'spend')::numeric, 0), coalesce((x->>'impressions')::bigint, 0), coalesce((x->>'clicks')::bigint, 0),
           (x->>'link_clicks')::bigint, coalesce((x->>'leads')::numeric, 0)::int, (x->>'video_views')::bigint, (x->>'frequency')::numeric, now()
      FROM jsonb_array_elements(p_items) x
     WHERE x->>'ad_ext' ~ '^[0-9]{3,25}$' AND x->>'day' ~ '^\d{4}-\d{2}-\d{2}$'
    ON CONFLICT (ad_ext, day) DO UPDATE SET account_id = EXCLUDED.account_id, adset_ext = EXCLUDED.adset_ext,
      campaign_ext = EXCLUDED.campaign_ext, spend = EXCLUDED.spend, impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
      link_clicks = EXCLUDED.link_clicks, leads = EXCLUDED.leads, video_views = EXCLUDED.video_views, frequency = EXCLUDED.frequency,
      updated_at = now()
    RETURNING 1)
  SELECT count(*)::int FROM ins $$;

-- One breakdown, replaced for the months it covers (so a bucket that disappeared does not linger).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_breakdowns_save(p_account uuid, p_kind text, p_from date, p_items jsonb) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
  DELETE FROM public.ads_meta_breakdown WHERE account_id = p_account AND kind = p_kind AND month >= date_trunc('month', p_from)::date;
  INSERT INTO public.ads_meta_breakdown (account_id, kind, month, k1, k2, spend, impressions, clicks, leads)
  SELECT p_account, p_kind, date_trunc('month', (x->>'month')::date)::date, left(coalesce(x->>'k1', ''), 80), left(coalesce(x->>'k2', ''), 80),
         sum(coalesce((x->>'spend')::numeric, 0)), sum(coalesce((x->>'impressions')::bigint, 0)),
         sum(coalesce((x->>'clicks')::bigint, 0)), sum(coalesce((x->>'leads')::numeric, 0))::int
    FROM jsonb_array_elements(p_items) x
   WHERE x->>'month' ~ '^\d{4}-\d{2}-\d{2}$' AND coalesce(x->>'k1', '') <> ''
   GROUP BY 3, 4, 5;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Progress of the history job: {cursor, done, recent, breakdowns} (only the keys given are changed).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_history_mark(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p ? 'cursor' THEN PERFORM crm_private.ads_meta_set_cfg('meta_history_cursor', coalesce(p->>'cursor', '')); END IF;
  IF (p->>'done')::boolean THEN PERFORM crm_private.ads_meta_set_cfg('meta_history_done_at', now()::text); END IF;
  IF (p->>'recent')::boolean THEN PERFORM crm_private.ads_meta_set_cfg('meta_history_recent_at', now()::text); END IF;
  IF (p->>'breakdowns')::boolean THEN PERFORM crm_private.ads_meta_set_cfg('meta_history_breakdowns_at', now()::text); END IF;
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_meta_set_cfg(p_key text, p_value text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

-- The monthly summary's numbers (whole account, both pipelines).
CREATE OR REPLACE FUNCTION public.svc_ads_meta_report_data(p_month date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT crm_private.ads_meta_insights_data(date_trunc('month', p_month)::date,
           (date_trunc('month', p_month) + interval '1 month - 1 day')::date, NULL, NULL, NULL) $$;

CREATE OR REPLACE FUNCTION public.svc_ads_meta_report_save(p_month date, p_data jsonb, p_patterns jsonb, p_emailed boolean, p_error text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_meta_report (month, data, patterns, emailed_at, email_error)
  VALUES (date_trunc('month', p_month)::date,
          jsonb_build_object('current', p_data->'current', 'previous', p_data->'previous', 'period', p_data->'period',
                             'board', jsonb_build_object('campaign', p_data->'board'->'campaign')),
          coalesce(p_patterns, '[]'), CASE WHEN p_emailed THEN now() END, left(p_error, 400))
  ON CONFLICT (month) DO UPDATE SET data = EXCLUDED.data, patterns = EXCLUDED.patterns,
    emailed_at = coalesce(EXCLUDED.emailed_at, public.ads_meta_report.emailed_at), email_error = EXCLUDED.email_error $$;

-- Cron: wake ads-sync only when there is history work to do.
CREATE OR REPLACE FUNCTION crm_private.ads_meta_history_wake() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.ads_accounts WHERE platform = 'meta' AND status = 'connected') THEN RETURN false; END IF;
  p := public.svc_ads_meta_history_plan();
  RETURN NOT (p->>'done')::boolean OR (p->>'recent_due')::boolean OR (p->>'breakdowns_due')::boolean OR p->>'report_month' IS NOT NULL;
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_days(date, date, text, text), crm_private.ads_meta_crm(date, date, text, text, text),
  crm_private.ads_meta_totals(date, date, text, text, text), crm_private.ads_meta_insights_data(date, date, text, text, text),
  crm_private.ads_meta_mail_ready(), crm_private.ads_meta_set_cfg(text, text), crm_private.ads_meta_history_wake() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_insights(date, date, text, text, text), public.api_ads_meta_note_save(date, text),
  public.api_ads_meta_note_delete(bigint), public.api_ads_meta_reports(), public.api_ads_meta_report_emails_save(jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_insights(date, date, text, text, text), public.api_ads_meta_note_save(date, text),
  public.api_ads_meta_note_delete(bigint), public.api_ads_meta_reports(), public.api_ads_meta_report_emails_save(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.svc_ads_meta_mail_config(), public.svc_ads_meta_history_plan(), public.svc_ads_meta_objects_save(uuid, jsonb),
  public.svc_ads_meta_ad_days_save(uuid, jsonb), public.svc_ads_meta_breakdowns_save(uuid, text, date, jsonb),
  public.svc_ads_meta_history_mark(jsonb), public.svc_ads_meta_report_data(date),
  public.svc_ads_meta_report_save(date, jsonb, jsonb, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_mail_config(), public.svc_ads_meta_history_plan(), public.svc_ads_meta_objects_save(uuid, jsonb),
  public.svc_ads_meta_ad_days_save(uuid, jsonb), public.svc_ads_meta_breakdowns_save(uuid, text, date, jsonb),
  public.svc_ads_meta_history_mark(jsonb), public.svc_ads_meta_report_data(date),
  public.svc_ads_meta_report_save(date, jsonb, jsonb, boolean, text) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '103')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- every hour at minute 50: back-fill the next months until done, then refresh daily / weekly, and the monthly summary
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-ads-meta-history';
    PERFORM cron.schedule('crm-ads-meta-history', '50 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["meta_history"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE crm_private.ads_meta_history_wake()
    $job$);
  END IF;
END $$;
