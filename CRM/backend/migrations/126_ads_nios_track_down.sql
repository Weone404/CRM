-- 126 down
DO $$ BEGIN
  IF to_regprocedure('public.api_ads_lead_board_v125(text,text,boolean,text,integer,text)') IS NOT NULL THEN
    DROP FUNCTION IF EXISTS public.api_ads_lead_board(text, text, boolean, text, integer, text, text);
    ALTER FUNCTION public.api_ads_lead_board_v125(text, text, boolean, text, integer, text) RENAME TO api_ads_lead_board;
    GRANT EXECUTE ON FUNCTION public.api_ads_lead_board(text, text, boolean, text, integer, text) TO authenticated;
  END IF;
END $$;
DROP TRIGGER IF EXISTS trg_ads_lead_track ON public.ads_enquiry;
DROP FUNCTION IF EXISTS crm_private.ads_lead_track_set();
DROP FUNCTION IF EXISTS crm_private.ads_lead_track(uuid);
ALTER TABLE public.ads_lead DROP CONSTRAINT IF EXISTS ads_lead_track_check;
ALTER TABLE public.ads_lead DROP COLUMN IF EXISTS track;
UPDATE public.ads_config SET value = '125', updated_at = now() WHERE key = 'ads_schema';
