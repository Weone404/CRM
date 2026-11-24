-- 136: comment-to-DM sends the brochure (PDF). Instagram allows one message to a commenter until they reply, so the private
-- reply invites a reply and the reply gets the PDF; someone who writes first gets it with the welcome. ig_dm.pdf_url must be a
-- public https link to a PDF (Instagram: up to 25 MB). Default: the We One Aviation prospectus hosted with the CRM.
-- Re-runnable. Down: 136_ig_dm_pdf_down.sql.
ALTER TABLE public.ig_dm_person ADD COLUMN IF NOT EXISTS pdf_at timestamptz;

UPDATE public.ads_config
   SET value = (value::jsonb || jsonb_build_object('pdf_url', 'https://crm-pi-self.vercel.app/files/we-one-aviation-brochure.pdf', 'pdf_name', 'brochure'))::text,
       updated_at = now()
 WHERE key = 'ig_dm' AND coalesce(value::jsonb->>'pdf_url', '') = '';

-- settings: + pdf_url (https, or empty to stop sending it) and pdf_name (what the messages call it)
DO $$ BEGIN
  IF to_regprocedure('public.api_ig_dm_settings_save_v135(jsonb)') IS NULL THEN
    ALTER FUNCTION public.api_ig_dm_settings_save(jsonb) RENAME TO api_ig_dm_settings_save_v135;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ig_dm_settings_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE u text; n text; cur jsonb;
BEGIN
  PERFORM crm_private.ads_require_admin();
  IF p ? 'pdf_url' THEN
    u := nullif(btrim(coalesce(p->>'pdf_url', '')), '');
    IF u IS NOT NULL AND (u !~ '^https://[^\s]+$' OR length(u) > 500) THEN RAISE EXCEPTION 'The brochure link must be a public https link' USING ERRCODE = 'PT422'; END IF;
  END IF;
  IF p ? 'pdf_name' THEN n := nullif(left(btrim(coalesce(p->>'pdf_name', '')), 40), ''); END IF;
  PERFORM public.api_ig_dm_settings_save_v135(p - 'pdf_url' - 'pdf_name');
  IF p ? 'pdf_url' OR p ? 'pdf_name' THEN
    cur := coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}');
    IF p ? 'pdf_url' THEN cur := cur || jsonb_build_object('pdf_url', u); END IF;
    IF p ? 'pdf_name' THEN cur := cur || jsonb_build_object('pdf_name', n); END IF;
    UPDATE public.ads_config SET value = cur::text, updated_at = now() WHERE key = 'ig_dm';
  END IF;
  RETURN jsonb_build_object('saved', true);
END $$;

-- the run's own state updates never touch the brochure settings
CREATE OR REPLACE FUNCTION public.svc_ig_dm_cfg(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value)
  VALUES ('ig_dm', (coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}')
                    || (coalesce(p, '{}') - 'on' - 'message' - 'thanks' - 'public_reply' - 'public_replies' - 'cap' - 'inbox' - 'crm' - 'pdf_url' - 'pdf_name'))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

REVOKE ALL ON FUNCTION public.api_ig_dm_settings_save(jsonb), public.api_ig_dm_settings_save_v135(jsonb), public.svc_ig_dm_cfg(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_settings_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ig_dm_cfg(jsonb) TO service_role;

-- status: how many brochures went out
DO $$ BEGIN
  IF to_regprocedure('public.api_ig_dm_status_v135()') IS NULL THEN ALTER FUNCTION public.api_ig_dm_status() RENAME TO api_ig_dm_status_v135; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.api_ig_dm_status() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.api_ig_dm_status_v135() || jsonb_build_object('brochures', (SELECT count(*) FROM public.ig_dm_person WHERE pdf_at IS NOT NULL)) $$;
REVOKE ALL ON FUNCTION public.api_ig_dm_status(), public.api_ig_dm_status_v135() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_status() TO authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '136') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
