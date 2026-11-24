-- 137: Comment-to-DM texts editable in CRM > Content > Instagram > Comment-to-DM
--  * welcome     : the first message to people who write to the account first (empty = the comment DM text)
--  * pdf_invite  : the line added to the comment DM when a brochure is set ({brochure} = its name)
--  * pdf_intro   : the line sent just before the PDF ({brochure} = its name)
-- The ig-dm run never overwrites these (svc_ig_dm_cfg drops them).
DO $$ BEGIN
  IF to_regprocedure('public.api_ig_dm_settings_save_v136(jsonb)') IS NULL THEN
    ALTER FUNCTION public.api_ig_dm_settings_save(jsonb) RENAME TO api_ig_dm_settings_save_v136;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.api_ig_dm_settings_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cur jsonb; k text; v text; lim int;
BEGIN
  PERFORM crm_private.ads_require_admin();
  PERFORM public.api_ig_dm_settings_save_v136(p - 'welcome' - 'pdf_invite' - 'pdf_intro');
  IF p ?| array['welcome', 'pdf_invite', 'pdf_intro'] THEN
    cur := coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}');
    FOREACH k IN ARRAY array['welcome', 'pdf_invite', 'pdf_intro'] LOOP
      CONTINUE WHEN NOT p ? k;
      lim := CASE k WHEN 'welcome' THEN 900 ELSE 300 END;
      v := nullif(btrim(coalesce(p->>k, '')), '');
      IF v IS NOT NULL AND length(v) > lim THEN RAISE EXCEPTION 'That text is too long (up to % characters)', lim USING ERRCODE = 'PT422'; END IF;
      cur := cur || jsonb_build_object(k, v);
    END LOOP;
    UPDATE public.ads_config SET value = cur::text, updated_at = now() WHERE key = 'ig_dm';
  END IF;
  RETURN jsonb_build_object('saved', true);
END $$;

CREATE OR REPLACE FUNCTION public.svc_ig_dm_cfg(p jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO public.ads_config (key, value)
  VALUES ('ig_dm', (coalesce(nullif(crm_private.ads_cfg('ig_dm'), '')::jsonb, '{}')
                    || (coalesce(p, '{}') - 'on' - 'message' - 'thanks' - 'public_reply' - 'public_replies' - 'cap' - 'inbox' - 'crm'
                        - 'pdf_url' - 'pdf_name' - 'welcome' - 'pdf_invite' - 'pdf_intro'))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() $$;

REVOKE ALL ON FUNCTION public.api_ig_dm_settings_save(jsonb), public.api_ig_dm_settings_save_v136(jsonb), public.svc_ig_dm_cfg(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_settings_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.svc_ig_dm_cfg(jsonb) TO service_role;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '137') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
