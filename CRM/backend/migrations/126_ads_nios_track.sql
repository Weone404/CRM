-- 126 NIOS route track for Ads leads.
--  * A lead that needs NIOS Physics & Maths before DGCA CPL gets track 'nios' and is worked as its own list (owner decision,
--    23 Nov 2026): it came from the NIOS ad set / form (plan v5 a3 / f3), answered a NIOS question ("12th kis stream se?",
--    "NIOS Physics-Maths ka status?"), or answered "Passed with other subjects" to "Class 12 status?" on the CPL form (f2).
--  * Stored as a column (ads_lead.track), not worked out on every read: the board counts it over all leads with one cheap
--    query, and the answer is read once, when the enquiry arrives, from the plan the form was built from. A later strategy
--    version can reorder its questions (q2 may stop being Class 12), which would change what an old coded answer decodes to.
--  * Set by a trigger on each new enquiry (the latest enquiry with a Class 12 answer decides) and backfilled here. A broken
--    answer never stops an enquiry from being saved.
--  * api_ads_lead_board: new optional p_track ('nios'), row.track and stats.nios. Wrapper-by-rename over 125 (_v125).
--  * "Qualified" on Meta Ads > Overview (121) and on the board is a stage a person sets after a call, so it is not changed:
--    the track is shown next to it so nobody marks a NIOS-route lead as a CPL-qualified lead by mistake.
--  * Conversions API: a NIOS-route lead is never reported to Meta at Qualified Lead or a later stage (Meta would learn to
--    find more people who cannot start CPL yet). Those events are kept as 'skipped' with the reason; earlier stages
--    (Lead Created, Contacted, Interested) are still reported. Wrapper-by-rename over 100's ads_meta_capi_queue (_v125).

ALTER TABLE public.ads_lead ADD COLUMN IF NOT EXISTS track text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ads_lead_track_check' AND conrelid = 'public.ads_lead'::regclass) THEN
    ALTER TABLE public.ads_lead ADD CONSTRAINT ads_lead_track_check CHECK (track IS NULL OR track IN ('nios'));
  END IF;
END $$;

-- Is this built Meta form / ad set a NIOS-route one? True when the plan form or ad set it was built from (build.steps
-- '<kind>:<key>' -> id; the newest version that has the key) says so: track "nios", or "NIOS" in its key or name
-- (plan v5: form f3 "WOA NIOS route - ...", ad set a3 "India | NIOS route | ...").
CREATE OR REPLACE FUNCTION crm_private.ads_meta_nios_object(p_kind text, p_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(bool_or(coalesce(o->>'track', '') = 'nios' OR coalesce(o->>'key', '') ~* 'nios' OR coalesce(o->>'name', '') ~* 'nios'), false)
    FROM public.ads_meta_strategy s
    JOIN LATERAL jsonb_each(s.build->'steps') e ON e.key = p_kind || ':' || split_part(e.key, ':', 2) AND e.value->>'id' = p_id
    JOIN LATERAL (SELECT v.plan FROM public.ads_meta_strategy_version v
                   WHERE v.strategy_id = s.id AND v.version <= coalesce((s.build->>'version')::int, s.approved_version, v.version)
                     AND CASE p_kind WHEN 'form' THEN v.plan->'forms' @> jsonb_build_array(jsonb_build_object('key', split_part(e.key, ':', 2)))
                         ELSE jsonb_path_exists(v.plan, '$.campaigns[*].adsets[*] ? (@.key == $k)', jsonb_build_object('k', split_part(e.key, ':', 2))) END
                   ORDER BY v.version DESC LIMIT 1) pv ON true
    JOIN LATERAL (SELECT f AS o FROM jsonb_array_elements(CASE WHEN p_kind = 'form' THEN coalesce(pv.plan->'forms', '[]') END) f
                   WHERE f->>'key' = split_part(e.key, ':', 2)
                  UNION ALL
                  SELECT a FROM jsonb_array_elements(CASE WHEN p_kind = 'adset' THEN coalesce(pv.plan->'campaigns', '[]') END) c,
                                jsonb_array_elements(coalesce(c->'adsets', '[]')) a
                   WHERE a->>'key' = split_part(e.key, ':', 2)) ob ON true
   WHERE p_id IS NOT NULL AND p_kind IN ('form', 'adset') $$;

-- The track a lead is on (NULL = the normal CPL track). 'nios' when:
--  * it came from a NIOS-route form or ad set (above), whatever it answered; or
--  * in its latest enquiry that answered a Class 12 / NIOS question: a question about NIOS or "12th kis stream se?" (the
--    NIOS form f3) was answered, or "Class 12 status?" was "Passed with other subjects" (the CPL form f2).
CREATE OR REPLACE FUNCTION crm_private.ads_lead_track(p_lead uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH l AS (SELECT * FROM public.ads_lead WHERE id = p_lead),
  e AS (SELECT e.id, e.received_at, coalesce(e.touch->>'form_id', e.reported_first_touch->>'form_id',
               (SELECT r.form_id FROM public.ads_meta_lead_raw r WHERE r.lead_id = p_lead LIMIT 1)) AS form_id, e.payload_extra
          FROM public.ads_enquiry e WHERE e.ads_lead_id = p_lead),
  x AS (SELECT e.id, e.received_at, replace(a->>'q', '_', ' ') AS q, replace(a->>'a', '_', ' ') AS a
          FROM e, jsonb_array_elements(crm_private.ads_meta_answer_text(e.form_id, e.payload_extra->'meta_answers')) a
         WHERE e.payload_extra ? 'meta_answers' AND replace(a->>'q', '_', ' ') ~* '(class\s*12|12th|nios)'),
  latest AS (SELECT id FROM x ORDER BY received_at DESC, id DESC LIMIT 1)
  SELECT CASE WHEN crm_private.ads_meta_nios_object('form', (SELECT first_touch->>'form_id' FROM l))
                OR crm_private.ads_meta_nios_object('adset', (SELECT first_touch->>'adset_id' FROM l))
                OR EXISTS (SELECT 1 FROM e WHERE crm_private.ads_meta_nios_object('form', e.form_id))
                OR (SELECT bool_or(x.q ~* 'nios' OR x.q ~* '12th\s+kis\s+stream' OR x.a ~* 'other\s+subjects?') FROM x WHERE x.id = (SELECT id FROM latest))
              THEN 'nios' END $$;

CREATE OR REPLACE FUNCTION crm_private.ads_lead_track_set() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t text;
BEGIN
  IF NEW.ads_lead_id IS NULL THEN RETURN NULL; END IF;
  BEGIN
    t := crm_private.ads_lead_track(NEW.ads_lead_id);
    UPDATE public.ads_lead SET track = t WHERE id = NEW.ads_lead_id AND track IS DISTINCT FROM t;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'ads_lead_track_set: %', SQLERRM;   -- the enquiry is kept either way
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_ads_lead_track ON public.ads_enquiry;
CREATE TRIGGER trg_ads_lead_track AFTER INSERT ON public.ads_enquiry FOR EACH ROW EXECUTE FUNCTION crm_private.ads_lead_track_set();

-- leads that came in before this migration
UPDATE public.ads_lead l SET track = crm_private.ads_lead_track(l.id)
 WHERE (EXISTS (SELECT 1 FROM public.ads_enquiry e WHERE e.ads_lead_id = l.id) OR l.first_touch ? 'adset_id' OR l.first_touch ? 'form_id')
   AND l.track IS DISTINCT FROM crm_private.ads_lead_track(l.id);

DO $$ BEGIN
  IF to_regprocedure('crm_private.ads_meta_capi_queue_v125()') IS NULL THEN
    ALTER FUNCTION crm_private.ads_meta_capi_queue() RENAME TO ads_meta_capi_queue_v125;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION crm_private.ads_meta_capi_queue() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_meta_capi_queue_v125();
  UPDATE public.ads_meta_capi_uploads u
     SET status = 'skipped', error = 'NIOS route lead (Class 12 without Physics & Maths): not reported to Meta as a CPL-qualified stage.'
    FROM public.ads_lead l, public.ads_stage_def d
   WHERE u.status = 'pending' AND l.id = u.lead_id AND l.track = 'nios'
     AND d.pipeline = l.pipeline AND d.stage = u.stage AND d.ord >= 40 AND d.stage <> 'lost';
  IF crm_private.ads_platform_paused('meta') THEN RETURN 0; END IF;
  RETURN (SELECT count(*) FROM public.ads_meta_capi_uploads u WHERE u.status = 'pending'
            AND (u.last_try_at IS NULL OR u.last_try_at < now() - interval '1 hour'));
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_meta_capi_queue(), crm_private.ads_meta_capi_queue_v125() FROM PUBLIC, anon, authenticated;

DO $$ BEGIN
  IF to_regprocedure('public.api_ads_lead_board_v125(text,text,boolean,text,integer,text)') IS NULL THEN
    ALTER FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) RENAME TO api_ads_lead_board_v125;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ads_lead_board(p_pipeline text DEFAULT 'pilot_training', p_stage text DEFAULT NULL, p_quarantined boolean DEFAULT false,
  p_search text DEFAULT NULL, p_limit integer DEFAULT 100, p_platform text DEFAULT NULL, p_track text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb; rows jsonb := '[]'; r jsonb; t text; n int := 0; lim int := least(greatest(coalesce(p_limit, 100), 1), 300);
BEGIN
  IF p_track IS NOT NULL AND p_track NOT IN ('nios') THEN RAISE EXCEPTION 'Unknown track' USING ERRCODE = 'PT400'; END IF;
  -- with a track filter, read the most recent 300 and keep that track's rows (the board never shows more than 300)
  o := public.api_ads_lead_board_v125(p_pipeline, p_stage, p_quarantined, p_search, CASE WHEN p_track IS NULL THEN lim ELSE 300 END, p_platform);
  IF o IS NULL OR jsonb_typeof(o->'rows') <> 'array' THEN RETURN o; END IF;
  FOR r IN SELECT value FROM jsonb_array_elements(o->'rows') LOOP
    SELECT l.track INTO t FROM public.ads_lead l WHERE l.id = (r->>'id')::uuid;
    CONTINUE WHEN p_track IS NOT NULL AND t IS DISTINCT FROM p_track;
    EXIT WHEN n >= lim;
    rows := rows || jsonb_build_array(r || jsonb_build_object('track', t));
    n := n + 1;
  END LOOP;
  RETURN o || jsonb_build_object('rows', rows, 'stats', coalesce(o->'stats', '{}') || jsonb_build_object('nios',
    (SELECT count(*) FROM public.ads_lead l
      WHERE l.pipeline = coalesce(p_pipeline, 'pilot_training') AND l.track = 'nios' AND NOT l.quarantined
        AND l.deleted_at IS NULL AND l.anonymised_at IS NULL
        AND (p_platform IS NULL OR p_platform = ANY (crm_private.ads_lead_platforms(l))))));
END $$;
REVOKE ALL ON FUNCTION crm_private.ads_lead_track(uuid), crm_private.ads_lead_track_set(), crm_private.ads_meta_nios_object(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_lead_board_v125(text, text, boolean, text, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text, text) TO authenticated;
INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '126') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
