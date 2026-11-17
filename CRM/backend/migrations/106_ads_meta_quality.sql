-- 106: Meta Ads > Lead quality and lead score. Run after 105. Re-runnable. Rollback: 106_ads_meta_quality_down.sql.
--
--  * Lead quality: which Meta leads become qualified leads and admissions, by form, campaign, ad set, ad, platform
--    (Facebook / Instagram), any lead-form answer (city, class 12, start date ...), time to first call, weekday and hour.
--    Built from the lead archive (every Meta lead with its answers) and the CRM stages. Meta itself only counts form
--    submissions; this is what the CRM adds.
--  * Lead score (0-100, hot / warm / cold): for each new Meta lead, learned from how similar past leads turned out
--    (smoothed so a few leads never swing it) plus the owner's own rules (for example "answer class 12 = Yes: +20").
--    Scores are kept in ads_lead_score with the reasons; counsellors see hot leads first.

CREATE TABLE IF NOT EXISTS public.ads_lead_score (
  archive_id bigint PRIMARY KEY REFERENCES public.ads_meta_lead_archive(id) ON DELETE CASCADE,
  ads_lead_id uuid, crm_lead_id uuid,
  score int NOT NULL CHECK (score BETWEEN 0 AND 100),
  band text NOT NULL CHECK (band IN ('hot', 'warm', 'cold')),
  reasons jsonb NOT NULL DEFAULT '[]',
  computed_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ads_lead_score_ads ON public.ads_lead_score (ads_lead_id);
ALTER TABLE public.ads_lead_score ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_lead_score FROM anon, authenticated;

INSERT INTO public.ads_config (key, value) VALUES
  ('lead_score_rules', '[]'),        -- [{field: "answer:<key>" | "form" | "campaign" | "platform", op: "equals" | "contains", value, points}]
  ('lead_score_hot', '60'),
  ('lead_score_warm', '35')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------------------------------- the leads, with outcomes
-- One row per archived Meta lead: its features and what happened (only leads the CRM can follow have an outcome).
CREATE OR REPLACE FUNCTION crm_private.ads_meta_lead_facts(p_from date, p_to date)
RETURNS TABLE (archive_id bigint, created_at timestamptz, form text, campaign text, adset text, ad text, platform text, answers jsonb,
  known boolean, qualified boolean, customer boolean, first_call_min numeric, ads_lead_id uuid, crm_lead_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT a.id, coalesce(a.created_time, a.created_at),
         coalesce(a.form_name, f.name, a.form_id, '(no form)'),
         coalesce(a.campaign_name, c.name, a.campaign_id, '(no campaign)'),
         coalesce(a.adset_name, s.name, a.adset_id, '(no ad set)'),
         coalesce(a.ad_name, o.name, a.ad_id, CASE WHEN a.is_organic THEN '(no ad: from the Page)' ELSE '(no ad)' END),
         CASE lower(coalesce(a.platform, x.touch->>'meta_platform', '')) WHEN 'fb' THEN 'Facebook' WHEN 'facebook' THEN 'Facebook'
           WHEN 'ig' THEN 'Instagram' WHEN 'instagram' THEN 'Instagram' WHEN '' THEN 'unknown' ELSE lower(coalesce(a.platform, x.touch->>'meta_platform')) END,
         a.answers,
         x.lead_id IS NOT NULL, coalesce(x.qualified, false), coalesce(x.customer, false),
         CASE WHEN l.first_response_at IS NOT NULL THEN round(extract(epoch FROM l.first_response_at - l.created_at)::numeric / 60, 1) END,
         a.ads_lead_id, a.crm_lead_id
    FROM public.ads_meta_lead_archive a
    LEFT JOIN public.ads_meta_forms f ON f.form_id = a.form_id
    LEFT JOIN public.ads_meta_object o ON o.level = 'ad' AND o.external_id = a.ad_id
    LEFT JOIN public.ads_meta_object s ON s.level = 'adset' AND s.external_id = coalesce(a.adset_id, o.adset_ext)
    LEFT JOIN public.ads_meta_object c ON c.level = 'campaign' AND c.external_id = coalesce(a.campaign_id, o.campaign_ext)
    LEFT JOIN public.ads_lead l ON l.id = a.ads_lead_id
    LEFT JOIN (SELECT DISTINCT ON (y.lead_id) y.* FROM crm_private.ads_ad_leads() y ORDER BY y.lead_id, y.created_at) x ON x.lead_id = a.ads_lead_id
   WHERE (coalesce(a.created_time, a.created_at) AT TIME ZONE 'Asia/Kolkata')::date BETWEEN p_from AND p_to $$;

-- Lead quality grouped by one dimension.
CREATE OR REPLACE FUNCTION public.api_ads_meta_lead_quality(p_from date, p_to date, p_dim text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text;
BEGIN
  PERFORM crm_private.ads_require_view();
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 1200 THEN RAISE EXCEPTION 'Pick a period of up to 1,200 days' USING ERRCODE = 'PT422'; END IF;
  IF p_dim NOT IN ('form', 'campaign', 'adset', 'ad', 'platform', 'speed', 'weekday', 'hour') AND p_dim !~ '^answer:.{1,80}$' THEN
    RAISE EXCEPTION 'Unknown grouping' USING ERRCODE = 'PT422';
  END IF;
  k := CASE WHEN p_dim LIKE 'answer:%' THEN substr(p_dim, 8) END;
  RETURN jsonb_build_object(
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('value', v, 'leads', n, 'known', kn, 'qualified', q, 'customers', cu,
        'q_rate', CASE WHEN kn > 0 THEN round(100.0 * q / kn, 1) END, 'c_rate', CASE WHEN kn > 0 THEN round(100.0 * cu / kn, 1) END,
        'median_first_call_min', mc, 'small', kn < 10) ORDER BY n DESC, v), '[]') FROM (
      SELECT CASE p_dim
               WHEN 'form' THEN x.form WHEN 'campaign' THEN x.campaign WHEN 'adset' THEN x.adset WHEN 'ad' THEN x.ad WHEN 'platform' THEN x.platform
               WHEN 'speed' THEN CASE WHEN NOT x.known THEN 'not followed in the CRM' WHEN x.first_call_min IS NULL THEN 'not called yet'
                 WHEN x.first_call_min <= 5 THEN '1. within 5 min' WHEN x.first_call_min <= 30 THEN '2. 5-30 min' WHEN x.first_call_min <= 120 THEN '3. 30 min - 2 h'
                 WHEN x.first_call_min <= 1440 THEN '4. 2-24 h' ELSE '5. after a day' END
               WHEN 'weekday' THEN to_char(x.created_at AT TIME ZONE 'Asia/Kolkata', 'ID. Dy')
               WHEN 'hour' THEN to_char(x.created_at AT TIME ZONE 'Asia/Kolkata', 'HH24:00')
               ELSE coalesce(nullif(btrim(x.answers->>k), ''), '(no answer)') END v,
             count(*) n, count(*) FILTER (WHERE x.known) kn, count(*) FILTER (WHERE x.qualified) q, count(*) FILTER (WHERE x.customer) cu,
             round((percentile_cont(0.5) WITHIN GROUP (ORDER BY x.first_call_min))::numeric) mc
        FROM crm_private.ads_meta_lead_facts(p_from, p_to) x GROUP BY 1) z),
    'totals', (SELECT jsonb_build_object('leads', count(*), 'known', count(*) FILTER (WHERE known), 'qualified', count(*) FILTER (WHERE qualified),
        'customers', count(*) FILTER (WHERE customer)) FROM crm_private.ads_meta_lead_facts(p_from, p_to)),
    'answer_keys', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', key, 'leads', n) ORDER BY n DESC), '[]') FROM (
        SELECT e.key, count(*) n FROM crm_private.ads_meta_lead_facts(p_from, p_to) x, jsonb_each(x.answers) e GROUP BY e.key LIMIT 40) z));
END $$;

-- ------------------------------------------------------------------------------------------- lead score
CREATE OR REPLACE FUNCTION crm_private.ads_lead_score_calc(p_archive bigint) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE me record; prior numeric; tot int; p numeric; reasons jsonb := '[]'; f record; rate numeric; lift numeric; w numeric;
        r jsonb; pts int := 0; v text; score int; hot int; warm int; model boolean := false; k text;
BEGIN
  SELECT * INTO me FROM crm_private.ads_meta_lead_facts(DATE '2000-01-01', DATE '2100-01-01') x WHERE x.archive_id = p_archive;
  IF me.archive_id IS NULL THEN RETURN NULL; END IF;
  -- history: the last 365 days of followed leads, other than this one
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ls_hist (form text, campaign text, adset text, ad text, platform text, answers jsonb, qualified boolean) ON COMMIT DROP;
  TRUNCATE pg_temp.ls_hist;
  INSERT INTO pg_temp.ls_hist SELECT x.form, x.campaign, x.adset, x.ad, x.platform, x.answers, x.qualified
    FROM crm_private.ads_meta_lead_facts(crm_private.ads_meta_today() - 365, crm_private.ads_meta_today()) x WHERE x.known AND x.archive_id <> p_archive;
  SELECT count(*), avg(CASE WHEN qualified THEN 1.0 ELSE 0 END) INTO tot, prior FROM pg_temp.ls_hist;
  IF tot >= 20 THEN
    model := true;
    p := prior;
    FOR f IN
      SELECT 'Form' lbl, me.form val, count(*) n, avg(CASE WHEN h.qualified THEN 1.0 ELSE 0 END) q FROM pg_temp.ls_hist h WHERE h.form = me.form
      UNION ALL SELECT 'Campaign', me.campaign, count(*), avg(CASE WHEN h.qualified THEN 1.0 ELSE 0 END) FROM pg_temp.ls_hist h WHERE h.campaign = me.campaign
      UNION ALL SELECT 'Ad', me.ad, count(*), avg(CASE WHEN h.qualified THEN 1.0 ELSE 0 END) FROM pg_temp.ls_hist h WHERE h.ad = me.ad
      UNION ALL SELECT 'Platform', me.platform, count(*), avg(CASE WHEN h.qualified THEN 1.0 ELSE 0 END) FROM pg_temp.ls_hist h WHERE h.platform = me.platform
      UNION ALL SELECT 'Answer "' || e.key || '"', e.value #>> '{}', count(*), avg(CASE WHEN h.qualified THEN 1.0 ELSE 0 END)
        FROM jsonb_each(coalesce(me.answers, '{}')) e JOIN pg_temp.ls_hist h ON h.answers->>e.key = e.value #>> '{}' GROUP BY e.key, e.value
    LOOP
      CONTINUE WHEN f.n < 5 OR f.val IS NULL;
      rate := (f.q * f.n + prior * 10) / (f.n + 10);           -- smoothed toward the average
      lift := rate / greatest(prior, 0.01);
      w := least(1, f.n / 20.0);
      p := p * power(lift, w);
      IF abs(lift - 1) >= 0.15 THEN
        reasons := reasons || jsonb_build_object('why', format('%s %s: %s%% of %s past leads qualified (average %s%%)', f.lbl, left(f.val, 60),
          round(100 * f.q), f.n, round(100 * prior)), 'effect', CASE WHEN lift > 1 THEN 'up' ELSE 'down' END);
      END IF;
    END LOOP;
    score := round(100 * least(0.95, greatest(0.02, p)));
  ELSE
    score := 50;
    reasons := reasons || jsonb_build_object('why', format('Only %s followed leads so far: the score uses your rules until there are 20', tot), 'effect', 'none');
  END IF;
  -- the owner's rules
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(crm_private.ads_cfg('lead_score_rules'), '[]')::jsonb) LOOP
    k := r->>'field';
    v := CASE WHEN k = 'form' THEN me.form WHEN k = 'campaign' THEN me.campaign WHEN k = 'platform' THEN me.platform
              WHEN k LIKE 'answer:%' THEN me.answers->>substr(k, 8) END;
    CONTINUE WHEN v IS NULL;
    IF (r->>'op' = 'equals' AND lower(btrim(v)) = lower(btrim(r->>'value'))) OR (r->>'op' = 'contains' AND position(lower(r->>'value') IN lower(v)) > 0) THEN
      pts := pts + coalesce((r->>'points')::int, 0);
      reasons := reasons || jsonb_build_object('why', format('Your rule: %s %s "%s" (%s%s)', replace(k, 'answer:', 'answer '), r->>'op', r->>'value',
        CASE WHEN (r->>'points')::int >= 0 THEN '+' ELSE '' END, r->>'points'), 'effect', CASE WHEN (r->>'points')::int >= 0 THEN 'up' ELSE 'down' END);
    END IF;
  END LOOP;
  score := greatest(0, least(100, score + pts));
  hot := coalesce(nullif(crm_private.ads_cfg('lead_score_hot'), '')::int, 60);
  warm := coalesce(nullif(crm_private.ads_cfg('lead_score_warm'), '')::int, 35);
  RETURN jsonb_build_object('score', score, 'band', CASE WHEN score >= hot THEN 'hot' WHEN score >= warm THEN 'warm' ELSE 'cold' END,
    'reasons', reasons, 'model', model, 'history', tot);
END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_lead_score_save(p_archive bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s jsonb := crm_private.ads_lead_score_calc(p_archive); a public.ads_meta_lead_archive;
BEGIN
  IF s IS NULL THEN RETURN; END IF;
  SELECT * INTO a FROM public.ads_meta_lead_archive WHERE id = p_archive;
  INSERT INTO public.ads_lead_score (archive_id, ads_lead_id, crm_lead_id, score, band, reasons, computed_at)
  VALUES (p_archive, a.ads_lead_id, a.crm_lead_id, (s->>'score')::int, s->>'band', s->'reasons', now())
  ON CONFLICT (archive_id) DO UPDATE SET ads_lead_id = EXCLUDED.ads_lead_id, crm_lead_id = EXCLUDED.crm_lead_id, score = EXCLUDED.score,
    band = EXCLUDED.band, reasons = EXCLUDED.reasons, computed_at = now();
END $$;

-- New leads are scored as they are archived (never blocks filing a lead).
CREATE OR REPLACE FUNCTION crm_private.ads_lead_score_trg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.source = 'crm' AND coalesce(NEW.created_time, NEW.created_at) > now() - interval '7 days' THEN
    BEGIN PERFORM crm_private.ads_lead_score_save(NEW.id); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'ads_lead_score: %', SQLERRM; END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_lead_score ON public.ads_meta_lead_archive;
CREATE TRIGGER trg_ads_lead_score AFTER INSERT ON public.ads_meta_lead_archive FOR EACH ROW EXECUTE FUNCTION crm_private.ads_lead_score_trg();

-- Scores for leads (for the Overview / Leads lists): by ads lead id.
CREATE OR REPLACE FUNCTION public.api_ads_lead_scores(p_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_object_agg(s.ads_lead_id, jsonb_build_object('score', s.score, 'band', s.band, 'reasons', s.reasons)), '{}')
            FROM public.ads_lead_score s WHERE s.ads_lead_id = ANY (p_ids[1:500]));
END $$;

-- Newest scored Meta leads (hot first) for the Lead quality page.
CREATE OR REPLACE FUNCTION public.api_ads_meta_scored_leads(p_days int DEFAULT 7) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('archive_id', a.id, 'name', split_part(coalesce(a.name, 'Lead'), ' ', 1), 'form', a.form_name,
      'campaign', a.campaign_name, 'created_at', coalesce(a.created_time, a.created_at), 'score', s.score, 'band', s.band, 'reasons', s.reasons,
      'called', l.first_response_at IS NOT NULL, 'stage', l.stage, 'ads_lead_id', a.ads_lead_id)
      ORDER BY (l.first_response_at IS NULL) DESC, s.score DESC, coalesce(a.created_time, a.created_at) DESC), '[]')
    FROM public.ads_lead_score s JOIN public.ads_meta_lead_archive a ON a.id = s.archive_id LEFT JOIN public.ads_lead l ON l.id = a.ads_lead_id
   WHERE coalesce(a.created_time, a.created_at) > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)))
   LIMIT 200);
END $$;

-- Score settings (Admin): rules and band thresholds; rescores the last 30 days.
CREATE OR REPLACE FUNCTION public.api_ads_lead_score_settings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object('rules', coalesce(crm_private.ads_cfg('lead_score_rules'), '[]')::jsonb,
    'hot', coalesce(nullif(crm_private.ads_cfg('lead_score_hot'), '')::int, 60), 'warm', coalesce(nullif(crm_private.ads_cfg('lead_score_warm'), '')::int, 35),
    'followed_leads_365d', (SELECT count(*) FROM crm_private.ads_meta_lead_facts(crm_private.ads_meta_today() - 365, crm_private.ads_meta_today()) WHERE known));
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_lead_score_save(p_rules jsonb, p_hot int, p_warm int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r jsonb; clean jsonb := '[]'; n int := 0; a record;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF jsonb_typeof(p_rules) <> 'array' OR jsonb_array_length(p_rules) > 50 THEN RAISE EXCEPTION 'Up to 50 rules' USING ERRCODE = 'PT422'; END IF;
  IF p_hot IS NULL OR p_warm IS NULL OR p_warm < 1 OR p_hot <= p_warm OR p_hot > 99 THEN RAISE EXCEPTION 'Hot must be above warm (1-99)' USING ERRCODE = 'PT422'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rules) LOOP
    IF coalesce(r->>'field', '') !~ '^(form|campaign|platform|answer:.{1,80})$' OR coalesce(r->>'op', '') NOT IN ('equals', 'contains')
       OR length(coalesce(r->>'value', '')) NOT BETWEEN 1 AND 120 OR coalesce(r->>'points', '') !~ '^-?\d{1,2}$' OR abs((r->>'points')::int) > 50 THEN
      RAISE EXCEPTION 'Each rule needs a field, equals / contains, a value and points between -50 and 50' USING ERRCODE = 'PT422';
    END IF;
    clean := clean || jsonb_build_object('field', r->>'field', 'op', r->>'op', 'value', btrim(r->>'value'), 'points', (r->>'points')::int);
  END LOOP;
  PERFORM crm_private.ads_meta_set_cfg('lead_score_rules', clean::text);
  PERFORM crm_private.ads_meta_set_cfg('lead_score_hot', p_hot::text);
  PERFORM crm_private.ads_meta_set_cfg('lead_score_warm', p_warm::text);
  FOR a IN SELECT id FROM public.ads_meta_lead_archive WHERE coalesce(created_time, created_at) > now() - interval '30 days' LIMIT 2000 LOOP
    PERFORM crm_private.ads_lead_score_save(a.id); n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'rescored', n);
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_meta_lead_facts(date, date), crm_private.ads_lead_score_calc(bigint), crm_private.ads_lead_score_save(bigint),
  crm_private.ads_lead_score_trg() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_meta_lead_quality(date, date, text), public.api_ads_lead_scores(uuid[]), public.api_ads_meta_scored_leads(int),
  public.api_ads_lead_score_settings(), public.api_ads_lead_score_save(jsonb, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_lead_quality(date, date, text), public.api_ads_lead_scores(uuid[]), public.api_ads_meta_scored_leads(int),
  public.api_ads_lead_score_settings(), public.api_ads_lead_score_save(jsonb, int, int) TO authenticated;

-- score the last 30 days once
DO $$
DECLARE a record;
BEGIN
  FOR a IN SELECT id FROM public.ads_meta_lead_archive WHERE coalesce(created_time, created_at) > now() - interval '30 days' LIMIT 2000 LOOP
    PERFORM crm_private.ads_lead_score_save(a.id);
  END LOOP;
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '106')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
