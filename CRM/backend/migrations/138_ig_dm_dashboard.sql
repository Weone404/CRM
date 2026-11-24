-- 138: Content > Instagram > Dashboard. What comes IN (messages, message requests, replies to our DM, numbers, leads)
-- is logged in ig_dm_event by the ig-dm run; what goes OUT is ig_dm_send; comments are ig_dm_log.
--  * in_message : a message from someone who wrote to us (not a commenter we messaged)
--  * in_reply   : a message from a commenter answering our DM
--  * in_new     : a new person writes first and follows the account (their chat lands in the inbox)
--  * in_request : a new person writes first and does not follow the account (a message request)
--  * phone      : a mobile number received;  lead : a CRM lead made from it
-- Days are India days (Asia/Kolkata).

CREATE TABLE IF NOT EXISTS public.ig_dm_event (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('in_message', 'in_reply', 'in_new', 'in_request', 'phone', 'lead')),
  person text,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ig_dm_event_created ON public.ig_dm_event (created_at DESC);
ALTER TABLE public.ig_dm_event ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ig_dm_event FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.ig_dm_event TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.ig_dm_event_id_seq TO service_role;

ALTER TABLE public.ig_dm_log ADD COLUMN IF NOT EXISTS permalink text;
ALTER TABLE public.ig_dm_person ADD COLUMN IF NOT EXISTS follows boolean;

-- the replies that came in before this log existed
INSERT INTO public.ig_dm_event (kind, person, created_at)
SELECT 'in_reply', p.person, p.last_in_at FROM public.ig_dm_person p
 WHERE p.source = 'comment' AND p.last_in_at IS NOT NULL AND p.last_in_at > p.dm_at
   AND NOT EXISTS (SELECT 1 FROM public.ig_dm_event e WHERE e.person = p.person);

CREATE OR REPLACE FUNCTION public.api_ig_dm_dashboard(p_days int DEFAULT 30) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n int := CASE WHEN p_days IN (7, 30, 90) THEN p_days ELSE 30 END;
  d1 date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  d0 date := d1 - (n - 1);
  t0 timestamptz := (d0::timestamp AT TIME ZONE 'Asia/Kolkata');
  p0 timestamptz := ((d0 - n)::timestamp AT TIME ZONE 'Asia/Kolkata');
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (
  WITH ev AS (   -- one row per thing that happened: (at, what, person)
    SELECT created_at ts_, 'comment' w, person, state, media_id, permalink FROM public.ig_dm_log WHERE created_at >= p0
    UNION ALL SELECT created_at, 'dm', person, NULL, NULL, NULL FROM public.ig_dm_log WHERE state = 'sent' AND created_at >= p0
    UNION ALL SELECT created_at, 'out_' || kind, NULL, NULL, NULL, NULL FROM public.ig_dm_send WHERE created_at >= p0
    UNION ALL SELECT created_at, kind, person, NULL, NULL, NULL FROM public.ig_dm_event WHERE created_at >= p0),
  cur AS (SELECT * FROM ev WHERE ts_ >= t0),
  tot AS (SELECT (ts_ >= t0) now_, w, count(*) c FROM ev GROUP BY 1, 2),
  days AS (SELECT generate_series(d0, d1, interval '1 day')::date d)
  SELECT jsonb_build_object(
    'days', n, 'from', d0, 'to', d1,
    'series', (SELECT jsonb_agg(r ORDER BY r->>'day') FROM (
      SELECT jsonb_build_object('day', days.d,
        'comments', count(cur.w) FILTER (WHERE cur.w = 'comment'),
        'dms', count(cur.w) FILTER (WHERE cur.w = 'dm'),
        'messages', count(cur.w) FILTER (WHERE cur.w IN ('in_message', 'in_reply')),
        'requests', count(cur.w) FILTER (WHERE cur.w = 'in_request'),
        'new_chats', count(cur.w) FILTER (WHERE cur.w IN ('in_new', 'in_request')),
        'brochures', count(cur.w) FILTER (WHERE cur.w = 'out_pdf'),
        'leads', count(cur.w) FILTER (WHERE cur.w = 'lead')) r
      FROM days LEFT JOIN cur ON (cur.ts_ AT TIME ZONE 'Asia/Kolkata')::date = days.d GROUP BY days.d) s),
    'totals', (SELECT coalesce(jsonb_object_agg(k, jsonb_build_object('now', a, 'before', b)), '{}') FROM (
      SELECT k, coalesce(sum(c) FILTER (WHERE now_), 0) a, coalesce(sum(c) FILTER (WHERE NOT now_), 0) b FROM (
        SELECT CASE w WHEN 'comment' THEN 'comments' WHEN 'dm' THEN 'dms' WHEN 'in_message' THEN 'messages' WHEN 'in_reply' THEN 'messages'
                      WHEN 'in_request' THEN 'requests' WHEN 'in_new' THEN 'inbox_new' WHEN 'out_pdf' THEN 'brochures' WHEN 'phone' THEN 'phones'
                      WHEN 'lead' THEN 'leads' WHEN 'out_welcome' THEN 'welcomes' WHEN 'out_public' THEN 'public_replies' END k, now_, c FROM tot) x
       WHERE k IS NOT NULL GROUP BY k) y),
    'funnel', jsonb_build_array(
      jsonb_build_object('step', 'Comments', 'n', (SELECT count(*) FROM cur WHERE w = 'comment')),
      jsonb_build_object('step', 'DM sent', 'n', (SELECT count(*) FROM cur WHERE w = 'dm')),
      jsonb_build_object('step', 'Replied to the DM', 'n', (SELECT count(DISTINCT person) FROM cur WHERE w = 'in_reply')),
      jsonb_build_object('step', 'Got the brochure', 'n', (SELECT count(*) FROM public.ig_dm_person WHERE source = 'comment' AND pdf_at >= t0)),
      jsonb_build_object('step', 'Sent a number', 'n', (SELECT count(DISTINCT c.person) FROM cur c JOIN public.ig_dm_person p ON p.person = c.person WHERE c.w = 'phone' AND p.source = 'comment')),
      jsonb_build_object('step', 'CRM lead', 'n', (SELECT count(DISTINCT c.person) FROM cur c JOIN public.ig_dm_person p ON p.person = c.person WHERE c.w = 'lead' AND p.source = 'comment'))),
    'handled', (SELECT coalesce(jsonb_object_agg(coalesce(reason, state), c), '{}') FROM
      (SELECT CASE WHEN state = 'skipped' THEN reason END reason, state, count(*) c FROM public.ig_dm_log WHERE created_at >= t0 GROUP BY 1, 2) h),
    'posts', (SELECT coalesce(jsonb_agg(p ORDER BY (p->>'comments')::int DESC), '[]') FROM (
      SELECT jsonb_build_object('media_id', media_id, 'permalink', max(permalink), 'comments', count(*),
                                'dms', count(*) FILTER (WHERE state = 'sent')) p
        FROM cur WHERE w = 'comment' AND media_id IS NOT NULL GROUP BY media_id ORDER BY count(*) DESC LIMIT 5) q),
    'inbox_split', jsonb_build_object(
      'inbox', (SELECT count(*) FROM cur WHERE w = 'in_new'), 'requests', (SELECT count(*) FROM cur WHERE w = 'in_request'),
      'commenters', (SELECT count(DISTINCT person) FROM cur WHERE w = 'in_reply'))
  ));
END $$;
REVOKE ALL ON FUNCTION public.api_ig_dm_dashboard(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_ig_dm_dashboard(int) TO authenticated;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '138') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
