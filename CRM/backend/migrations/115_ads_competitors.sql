-- 115: Meta Ads > Strategy > Competitor watch. Run after 114. Re-runnable. Rollback: 115_ads_competitors_down.sql.
--  * Free sources only. Meta's Ad Library API does not return Indian commercial ads, and the Ad Library page needs a browser,
--    so competitors' ads are added here by hand (text, format, the "Started running on" date, links). Ads that have run for
--    weeks are the ones that work for them: days_running ranks them.
--  * The Strategy Researcher reads all of it (CONTEXT.competitors), adds what is public now, and its findings (each
--    competitor's strongest idea and the gap it leaves) are kept here after every research run.

CREATE TABLE IF NOT EXISTS public.ads_competitor (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  domain text,
  facebook_page text,
  instagram text,
  notes text,
  enabled boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS ux_ads_competitor_name ON public.ads_competitor (lower(name));

CREATE TABLE IF NOT EXISTS public.ads_competitor_ad (
  id bigserial PRIMARY KEY,
  competitor_id bigint NOT NULL REFERENCES public.ads_competitor(id) ON DELETE CASCADE,
  platform text NOT NULL DEFAULT 'meta' CHECK (platform IN ('meta', 'google', 'youtube', 'other')),
  format text NOT NULL DEFAULT 'image' CHECK (format IN ('image', 'video', 'carousel', 'text', 'other')),
  url text,
  started_on date,
  last_seen date NOT NULL DEFAULT current_date,
  primary_text text,
  headline text,
  cta text,
  landing_url text,
  offer text,
  angle text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_ads_competitor_ad ON public.ads_competitor_ad (competitor_id, started_on);

CREATE TABLE IF NOT EXISTS public.ads_competitor_finding (
  id bigserial PRIMARY KEY,
  competitor_id bigint REFERENCES public.ads_competitor(id) ON DELETE CASCADE,
  name text NOT NULL,
  strongest text,
  gap text,
  angle text,
  run_id bigint,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_ads_competitor_finding ON public.ads_competitor_finding (competitor_id, created_at DESC);

ALTER TABLE public.ads_competitor ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_competitor_ad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ads_competitor_finding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ads_competitor, public.ads_competitor_ad, public.ads_competitor_finding FROM PUBLIC, anon, authenticated;

-- names the owner already benchmarks against; more are added in the CRM
INSERT INTO public.ads_competitor (name, notes) VALUES
  ('Capt. Sahil Khurana Aviation Academy (CSKAA)', 'Dwarka Sector 7, New Delhi: the local benchmark.'),
  ('Golden Epaulettes Aviation', 'Delhi; publishes CPL cost guides.')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------------------------------------- reading
CREATE OR REPLACE FUNCTION crm_private.ads_competitors_data(p_ads_each int DEFAULT 20) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'domain', c.domain, 'facebook_page', c.facebook_page, 'instagram', c.instagram, 'notes', c.notes, 'enabled', c.enabled,
      'ads', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'platform', a.platform, 'format', a.format, 'url', a.url, 'started_on', a.started_on,
                'last_seen', a.last_seen, 'days_running', CASE WHEN a.started_on IS NOT NULL THEN a.last_seen - a.started_on END,
                'primary_text', a.primary_text, 'headline', a.headline, 'cta', a.cta, 'landing_url', a.landing_url, 'offer', a.offer, 'angle', a.angle)
                ORDER BY (a.last_seen - a.started_on) DESC NULLS LAST, a.id DESC), '[]')
              FROM (SELECT * FROM public.ads_competitor_ad x WHERE x.competitor_id = c.id
                     ORDER BY (x.last_seen - x.started_on) DESC NULLS LAST, x.id DESC LIMIT p_ads_each) a),
      'findings', (SELECT coalesce(jsonb_agg(jsonb_build_object('strongest', f.strongest, 'gap', f.gap, 'angle', f.angle, 'at', f.created_at)
                    ORDER BY f.created_at DESC), '[]')
              FROM (SELECT * FROM public.ads_competitor_finding y WHERE y.competitor_id = c.id ORDER BY y.created_at DESC LIMIT 3) f))
    ORDER BY c.enabled DESC, c.name), '[]')
  FROM public.ads_competitor c $$;

CREATE OR REPLACE FUNCTION public.api_ads_competitors() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN jsonb_build_object('items', crm_private.ads_competitors_data(50), 'can_edit', crm_private.ads_can_approve(),
    'other_findings', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', f.name, 'strongest', f.strongest, 'gap', f.gap, 'at', f.created_at) ORDER BY f.created_at DESC), '[]')
       FROM (SELECT * FROM public.ads_competitor_finding WHERE competitor_id IS NULL ORDER BY created_at DESC LIMIT 10) f));
END $$;

-- ------------------------------------------------------------------------------------------- editing (approvers)
CREATE OR REPLACE FUNCTION public.api_ads_competitor_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE nm text := btrim(coalesce(p->>'name', '')); dom text := lower(btrim(coalesce(p->>'domain', ''))); rid bigint;
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can edit competitors' USING ERRCODE = 'PT403'; END IF;
  IF length(nm) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Give the competitor a name (2-120 characters)' USING ERRCODE = 'PT422'; END IF;
  dom := regexp_replace(regexp_replace(dom, '^https?://', ''), '^www\.|/.*$', '', 'g');
  IF dom <> '' AND dom !~ '^[a-z0-9.-]+\.[a-z]{2,}$' THEN RAISE EXCEPTION 'Website looks like example.com' USING ERRCODE = 'PT422'; END IF;
  IF jsonb_typeof(p->'id') = 'number' THEN
    UPDATE public.ads_competitor SET name = nm, domain = nullif(dom, ''), facebook_page = nullif(left(btrim(coalesce(p->>'facebook_page', '')), 300), ''),
      instagram = nullif(left(btrim(coalesce(p->>'instagram', '')), 100), ''), notes = nullif(left(btrim(coalesce(p->>'notes', '')), 1000), ''),
      enabled = coalesce((p->>'enabled')::boolean, enabled), updated_at = now()
     WHERE id = (p->>'id')::bigint RETURNING id INTO rid;
    IF rid IS NULL THEN RAISE EXCEPTION 'Competitor not found' USING ERRCODE = 'PT404'; END IF;
  ELSE
    INSERT INTO public.ads_competitor (name, domain, facebook_page, instagram, notes, created_by)
    VALUES (nm, nullif(dom, ''), nullif(left(btrim(coalesce(p->>'facebook_page', '')), 300), ''), nullif(left(btrim(coalesce(p->>'instagram', '')), 100), ''),
            nullif(left(btrim(coalesce(p->>'notes', '')), 1000), ''), crm_private.current_employee_id())
    ON CONFLICT ((lower(name))) DO UPDATE SET domain = coalesce(EXCLUDED.domain, public.ads_competitor.domain), enabled = true, updated_at = now()
    RETURNING id INTO rid;
  END IF;
  RETURN jsonb_build_object('id', rid);
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_competitor_ad_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cid bigint := nullif(p->>'competitor_id', '')::bigint; st date; rid bigint; u text := btrim(coalesce(p->>'url', ''));
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can edit competitors' USING ERRCODE = 'PT403'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ads_competitor WHERE id = cid) THEN RAISE EXCEPTION 'Pick the competitor' USING ERRCODE = 'PT422'; END IF;
  IF length(btrim(coalesce(p->>'primary_text', '') || coalesce(p->>'headline', ''))) < 3 THEN
    RAISE EXCEPTION 'Paste the ad text or its headline' USING ERRCODE = 'PT422'; END IF;
  IF u <> '' AND u !~ '^https://' THEN RAISE EXCEPTION 'Links start with https://' USING ERRCODE = 'PT422'; END IF;
  BEGIN st := nullif(p->>'started_on', '')::date; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Started running on: a date like 2026-10-01' USING ERRCODE = 'PT422'; END;
  IF st > current_date THEN RAISE EXCEPTION 'The start date is in the future' USING ERRCODE = 'PT422'; END IF;
  INSERT INTO public.ads_competitor_ad (competitor_id, platform, format, url, started_on, last_seen, primary_text, headline, cta, landing_url, offer, angle, created_by)
  VALUES (cid, coalesce(nullif(p->>'platform', ''), 'meta'), coalesce(nullif(p->>'format', ''), 'image'), nullif(left(u, 600), ''), st,
          coalesce(nullif(p->>'last_seen', '')::date, current_date), nullif(left(p->>'primary_text', 3000), ''), nullif(left(p->>'headline', 200), ''),
          nullif(left(p->>'cta', 40), ''), nullif(left(btrim(coalesce(p->>'landing_url', '')), 600), ''), nullif(left(p->>'offer', 300), ''),
          nullif(left(p->>'angle', 200), ''), crm_private.current_employee_id())
  RETURNING id INTO rid;
  RETURN jsonb_build_object('id', rid);
END $$;

-- still running today: moves last_seen so days_running keeps counting
CREATE OR REPLACE FUNCTION public.api_ads_competitor_ad_seen(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can edit competitors' USING ERRCODE = 'PT403'; END IF;
  UPDATE public.ads_competitor_ad SET last_seen = current_date WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.api_ads_competitor_delete(p_kind text, p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can edit competitors' USING ERRCODE = 'PT403'; END IF;
  IF p_kind = 'ad' THEN DELETE FROM public.ads_competitor_ad WHERE id = p_id;
  ELSIF p_kind = 'competitor' THEN DELETE FROM public.ads_competitor WHERE id = p_id;
  ELSE RAISE EXCEPTION 'Unknown kind' USING ERRCODE = 'PT422'; END IF;
END $$;

-- ------------------------------------------------------------------------------------------- the Researcher's findings are kept
CREATE OR REPLACE FUNCTION crm_private.ads_competitor_findings_keep() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c jsonb; cid bigint;
BEGIN
  IF NEW.role = 'meta_researcher' AND NEW.status = 'done' AND OLD.status IS DISTINCT FROM 'done' AND jsonb_typeof(NEW.output->'competitors') = 'array' THEN
    FOR c IN SELECT * FROM jsonb_array_elements(NEW.output->'competitors') LIMIT 20 LOOP
      CONTINUE WHEN coalesce(btrim(c->>'name'), '') = '' OR (coalesce(c->>'strongest', '') = '' AND coalesce(c->>'gap', '') = '' AND coalesce(c->>'angle', '') = '');
      SELECT x.id INTO cid FROM public.ads_competitor x
       WHERE lower(x.name) = lower(btrim(c->>'name')) OR (x.domain IS NOT NULL AND lower(coalesce(c->>'domain', '')) LIKE '%' || x.domain || '%')
          OR lower(x.name) LIKE '%' || lower(left(btrim(c->>'name'), 30)) || '%' ORDER BY x.id LIMIT 1;
      INSERT INTO public.ads_competitor_finding (competitor_id, name, strongest, gap, angle, run_id)
      VALUES (cid, left(btrim(c->>'name'), 120), left(c->>'strongest', 500), left(c->>'gap', 500), left(c->>'angle', 300), NEW.id);
    END LOOP;
    DELETE FROM public.ads_competitor_finding WHERE id IN (
      SELECT id FROM (SELECT id, row_number() OVER (PARTITION BY coalesce(competitor_id, -1), lower(name) ORDER BY created_at DESC) rn
                        FROM public.ads_competitor_finding) z WHERE rn > 10);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_ads_competitor_findings ON public.ads_agent_runs;
CREATE TRIGGER trg_ads_competitor_findings AFTER UPDATE OF status ON public.ads_agent_runs
  FOR EACH ROW EXECUTE FUNCTION crm_private.ads_competitor_findings_keep();

-- ------------------------------------------------------------------------------------------- agents' context: + competitors
DO $$
BEGIN
  IF to_regprocedure('public.svc_ads_meta_strategy_extra_v114()') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_strategy_extra() RENAME TO svc_ads_meta_strategy_extra_v114;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.svc_ads_meta_strategy_extra() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN public.svc_ads_meta_strategy_extra_v114() || jsonb_build_object('competitors', (
    SELECT coalesce(jsonb_agg(x - 'id' - 'enabled'), '[]') FROM jsonb_array_elements(crm_private.ads_competitors_data(10)) x WHERE (x->>'enabled')::boolean));
END $$;

REVOKE ALL ON FUNCTION crm_private.ads_competitors_data(int), crm_private.ads_competitor_findings_keep() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_ads_competitors(), public.api_ads_competitor_save(jsonb), public.api_ads_competitor_ad_save(jsonb),
  public.api_ads_competitor_ad_seen(bigint), public.api_ads_competitor_delete(text, bigint), public.svc_ads_meta_strategy_extra() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ads_competitors(), public.api_ads_competitor_save(jsonb), public.api_ads_competitor_ad_save(jsonb),
  public.api_ads_competitor_ad_seen(bigint), public.api_ads_competitor_delete(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ads_meta_strategy_extra() TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '115')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
