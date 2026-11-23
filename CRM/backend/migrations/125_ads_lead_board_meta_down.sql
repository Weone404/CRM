-- 125 down
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_lead_board_v124(text,text,boolean,text,integer,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_lead_board(text, text, boolean, text, integer, text);
    ALTER FUNCTION public.api_ads_lead_board_v124(text, text, boolean, text, integer, text) RENAME TO api_ads_lead_board;
    GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) TO authenticated;
  END IF;
END $$;
DROP FUNCTION IF EXISTS crm_private.ads_meta_ad_label(text);
UPDATE public.ads_config SET value = '124', updated_at = now() WHERE key = 'ads_schema';
