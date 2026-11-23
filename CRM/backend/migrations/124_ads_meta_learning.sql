-- 124 Meta Ads learning loop.
--  * ads_meta_lesson: what this account's own Meta tests taught (and the owner's decisions), with the evidence. The Strategist and
--    Reviewer read the active ones (CONTEXT.lessons) and the Strategist adds new ones when it revises a plan after a test.
--  * CONTEXT.last_test: the running strategy's own results per ad (spend, views, cost per 1,000 views, click rate, leads, cost per
--    lead), what its leads answered, and how many were called / qualified, so a revision starts from the real test.
--  * Readable form answers: forms the CRM builds store answers as q1/q1o2; ads_meta_answer_text() turns them back into the
--    question and option text of the plan the form came from. Meta Ads > Overview shows them that way.

CREATE TABLE IF NOT EXISTS public.ads_meta_lesson (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lesson text NOT NULL CHECK (length(lesson) BETWEEN 10 AND 400),
  evidence text NOT NULL DEFAULT '' CHECK (length(evidence) <= 600),
  source text NOT NULL DEFAULT 'test' CHECK (source IN ('test', 'owner', 'strategist')),
  strategy_id bigint REFERENCES public.ads_meta_strategy(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS ads_meta_lesson_text_idx ON public.ads_meta_lesson (lower(lesson));
ALTER TABLE public.ads_meta_lesson ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_meta_lesson FROM anon, authenticated;

-- q1 / q1o2 -> the question and option text of the plan form the CRM built (form id from the build steps)
CREATE OR REPLACE FUNCTION crm_private.ads_meta_answer_text(p_form text, p_answers jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE qs jsonb; out jsonb := '[]'; k text; v text; n int; o int; q jsonb;
BEGIN
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' THEN RETURN '[]'; END IF;
  SELECT coalesce(jsonb_agg(x ORDER BY ord), '[]') INTO qs FROM (
    SELECT x, ord FROM public.ads_meta_strategy s
      JOIN LATERAL jsonb_each(s.build->'steps') e ON e.key LIKE 'form:%' AND e.value->>'id' = p_form
      JOIN public.ads_meta_strategy_version ver ON ver.strategy_id = s.id AND ver.version = coalesce((s.build->>'version')::int, s.approved_version)
      JOIN LATERAL jsonb_array_elements(ver.plan->'forms') f ON f->>'key' = split_part(e.key, ':', 2)
      JOIN LATERAL jsonb_array_elements(f->'questions') WITH ORDINALITY qq(x, ord) ON x->>'type' = 'CUSTOM'
     WHERE p_form IS NOT NULL LIMIT 20) z;
  FOR k, v IN SELECT key, value #>> '{}' FROM jsonb_each(p_answers) ORDER BY key LOOP
    n := nullif(substring(k FROM '^q(\d+)$'), '')::int;
    IF n IS NOT NULL AND n <= jsonb_array_length(qs) THEN
      q := qs->(n - 1);
      o := nullif(substring(v FROM '^q\d+o(\d+)$'), '')::int;
      out := out || jsonb_build_object('q', q->>'label', 'a', coalesce(q->'options'->>(o - 1), v));
    ELSIF k !~* '(name|phone|email|mobile|number)' THEN
      out := out || jsonb_build_object('q', initcap(replace(k, '_', ' ')), 'a', v);
    END IF;
  END LOOP;
  RETURN out;
END $$;

-- a lead's readable answers (from the enquiry the lead was filed from)
CREATE OR REPLACE FUNCTION crm_private.ads_meta_lead_answers(p_lead uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT crm_private.ads_meta_answer_text(coalesce(e.touch->>'form_id', e.reported_first_touch->>'form_id',
                    (SELECT r.form_id FROM public.ads_meta_lead_raw r WHERE r.lead_id = p_lead LIMIT 1)), e.payload_extra->'meta_answers')
                     FROM public.ads_enquiry e WHERE e.ads_lead_id = p_lead AND e.payload_extra ? 'meta_answers' ORDER BY e.received_at LIMIT 1), '[]') $$;

-- Meta Ads > Overview: latest responses in words
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_meta_live_v122()') IS NULL THEN ALTER FUNCTION public.api_ads_meta_live() RENAME TO api_ads_meta_live_v122; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ads_meta_live() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_ads_meta_live_v122(); camps jsonb := '[]'; c jsonb; lat jsonb; l jsonb; a jsonb;
BEGIN
  FOR c IN SELECT value FROM jsonb_array_elements(coalesce(o->'campaigns', '[]')) LOOP
    lat := '[]';
    FOR l IN SELECT value FROM jsonb_array_elements(coalesce(c->'latest', '[]')) LOOP
      a := CASE WHEN l->>'lead_id' IS NOT NULL THEN crm_private.ads_meta_lead_answers((l->>'lead_id')::uuid) ELSE '[]' END;
      lat := lat || jsonb_build_array(CASE WHEN jsonb_array_length(a) > 0 THEN l || jsonb_build_object('answers', a) ELSE l END);
    END LOOP;
    camps := camps || jsonb_build_array(c || jsonb_build_object('latest', lat));
  END LOOP;
  RETURN o || jsonb_build_object('campaigns', camps);
END $$;

-- the running strategy's own test, for the Strategist and Reviewer
CREATE OR REPLACE FUNCTION crm_private.ads_meta_last_test(p_strategy bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.ads_meta_strategy; ads jsonb; leads jsonb; ad_ids text[];
BEGIN
  SELECT * INTO s FROM public.ads_meta_strategy WHERE id = p_strategy;
  IF NOT FOUND OR NOT (s.build ? 'steps') THEN RETURN NULL; END IF;
  ad_ids := ARRAY(SELECT e.value->>'id' FROM jsonb_each(s.build->'steps') e WHERE e.key LIKE 'ad:%' AND e.value->>'id' IS NOT NULL);
  SELECT coalesce(jsonb_agg(row ORDER BY row->>'creative'), '[]') INTO ads FROM (
    SELECT jsonb_build_object('creative', split_part(e.key, ':', 3), 'ad_id', e.value->>'id',
           'days', count(DISTINCT d.day), 'spend', round(coalesce(sum(d.spend), 0), 2), 'views', coalesce(sum(d.impressions), 0),
           'link_clicks', coalesce(sum(d.link_clicks), 0), 'meta_leads', coalesce(sum(d.leads), 0),
           'cost_per_1000_views', CASE WHEN sum(d.impressions) > 0 THEN round(1000 * sum(d.spend) / sum(d.impressions)) END,
           'click_rate_pct', CASE WHEN sum(d.impressions) > 0 THEN round(100.0 * sum(d.link_clicks) / sum(d.impressions), 2) END,
           'cost_per_lead', CASE WHEN sum(d.leads) > 0 THEN round(sum(d.spend) / sum(d.leads)) END) row
      FROM jsonb_each(s.build->'steps') e LEFT JOIN public.ads_meta_ad_day d ON d.ad_ext = e.value->>'id'
     WHERE e.key LIKE 'ad:%' GROUP BY e.key, e.value) z;
  SELECT coalesce(jsonb_agg(jsonb_build_object('at', r.created_time, 'ad_id', r.ad_id, 'answers', crm_private.ads_meta_lead_answers(r.lead_id),
           'stage', l.stage, 'called', l.first_response_at IS NOT NULL,
           'hours_to_first_call', CASE WHEN l.first_response_at IS NOT NULL THEN round(extract(epoch FROM l.first_response_at - coalesce(r.created_time, r.received_at)) / 3600, 1) END)
           ORDER BY r.received_at), '[]') INTO leads
    FROM public.ads_meta_lead_raw r LEFT JOIN public.ads_lead l ON l.id = r.lead_id
   WHERE r.ad_id = ANY (ad_ids) AND coalesce(r.status, '') NOT IN ('test', 'organic');
  RETURN jsonb_build_object('strategy_id', s.id, 'version', s.build->'version', 'built_at', s.build->'at', 'ads', ads, 'leads', leads,
    'note', 'Per-ad results of the plan now running (CRM: ads_meta_ad_day from Meta, leads from the CRM). Small numbers: say how sure you are.');
END $$;

DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_agent_ctx_v123(public.ads_agent_runs)') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_agent_ctx(public.ads_agent_runs) RENAME TO ads_meta_agent_ctx_v123;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.ads_meta_agent_ctx(p_run public.ads_agent_runs) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := crm_private.ads_meta_agent_ctx_v123(p_run); sid bigint := nullif(p_run.input->>'strategy_id', '')::bigint;
BEGIN
  IF o IS NULL THEN RETURN o; END IF;
  sid := coalesce(sid, nullif(o->'strategy'->>'id', '')::bigint);
  RETURN o || jsonb_build_object(
    'lessons', (SELECT coalesce(jsonb_agg(jsonb_build_object('lesson', x.lesson, 'evidence', x.evidence, 'source', x.source, 'since', x.created_at::date) ORDER BY x.id), '[]')
                  FROM public.ads_meta_lesson x WHERE x.active),
    'last_test', CASE WHEN sid IS NOT NULL THEN crm_private.ads_meta_last_test(sid) END);
END $$;

-- the Strategist's lessons from a test are kept (at most 5 a run, 25 active, the oldest retire first)
CREATE OR REPLACE FUNCTION crm_private.ads_meta_keep_lessons() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x jsonb;
BEGIN
  IF NEW.role = 'meta_strategist' AND NEW.status = 'done' AND OLD.status IS DISTINCT FROM 'done' AND jsonb_typeof(NEW.output->'lessons') = 'array' THEN
    FOR x IN SELECT value FROM jsonb_array_elements(NEW.output->'lessons') WITH ORDINALITY t(value, i) WHERE i <= 5 LOOP
      IF length(coalesce(x->>'lesson', '')) BETWEEN 10 AND 400 THEN
        INSERT INTO public.ads_meta_lesson (lesson, evidence, source, strategy_id)
        VALUES (x->>'lesson', left(coalesce(x->>'evidence', ''), 600), 'strategist', nullif(NEW.input->>'strategy_id', '')::bigint)
        ON CONFLICT ((lower(lesson))) DO UPDATE SET evidence = EXCLUDED.evidence, active = true;
      END IF;
    END LOOP;
    UPDATE public.ads_meta_lesson SET active = false
     WHERE active AND source <> 'owner' AND id NOT IN (SELECT id FROM public.ads_meta_lesson WHERE active ORDER BY (source = 'owner') DESC, id DESC LIMIT 25);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS ads_meta_keep_lessons ON public.ads_agent_runs;
CREATE TRIGGER ads_meta_keep_lessons AFTER UPDATE OF status ON public.ads_agent_runs FOR EACH ROW EXECUTE FUNCTION crm_private.ads_meta_keep_lessons();

REVOKE ALL ON FUNCTION crm_private.ads_meta_answer_text(text, jsonb), crm_private.ads_meta_lead_answers(uuid), crm_private.ads_meta_last_test(bigint),
  crm_private.ads_meta_agent_ctx(public.ads_agent_runs), crm_private.ads_meta_agent_ctx_v123(public.ads_agent_runs) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_meta_live(), public.api_ads_meta_live_v122() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.api_ads_meta_live_v122() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_meta_live() TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '124') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
