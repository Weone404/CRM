-- 119 Ad studio (Growth > Content > Ad creatives): every ad goes Made -> Approved -> Posted on Instagram -> In ads -> Results,
-- run from the CRM.
--  * Approve an ad, write its caption (it becomes the ad text), schedule the Instagram post (with the AI info label for
--    AI-presenter videos). ads-sync posts it at that time (cron every 5 minutes), then reads its views, likes, saves and
--    comments every hour; comments can be answered or hidden from the CRM.
--  * "Use in ads" puts the posted Instagram post into a strategy's ad slot: Create in Meta then makes the ad from that
--    post (likes and comments stay on one post) instead of uploading the file again. Everything is still created PAUSED.
--  * The campaign bar shows the budget, the 7-day learning lock and live on/paused state; Pause / Switch on use the
--    existing Meta actions (110) so the same approval and audit rules apply.
-- Wrapper-by-rename (as 117): api_content_item_save, api_content_overview and svc_ads_meta_build_work gain the new parts.

ALTER TABLE public.content_item ADD COLUMN IF NOT EXISTS caption text;
ALTER TABLE public.content_item ADD COLUMN IF NOT EXISTS approved_at timestamptz;
ALTER TABLE public.content_item ADD COLUMN IF NOT EXISTS post_at timestamptz;
ALTER TABLE public.content_item ADD COLUMN IF NOT EXISTS post_ai boolean NOT NULL DEFAULT false;
ALTER TABLE public.content_item ADD COLUMN IF NOT EXISTS ig jsonb NOT NULL DEFAULT '{}';   -- media_id, permalink, posted_at, tries, error, stats, stats_at
CREATE INDEX IF NOT EXISTS ix_content_item_post ON public.content_item (post_at) WHERE post_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.content_comment (
  ig_id text PRIMARY KEY CHECK (ig_id ~ '^[0-9]{3,30}$'),
  item_id bigint NOT NULL REFERENCES public.content_item(id) ON DELETE CASCADE,
  username text, body text, at timestamptz,
  seen boolean NOT NULL DEFAULT false, hidden boolean NOT NULL DEFAULT false,
  reply text, replied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_content_comment_item ON public.content_comment (item_id, at DESC);
ALTER TABLE public.content_comment ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.content_comment FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------ ad slots of a strategy (video and image creatives)
CREATE OR REPLACE FUNCTION crm_private.content_ad_slots() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('strategy_id', s.id, 'strategy', s.title, 'approved', s.approved_version IS NOT NULL,
           'key', c->>'key', 'name', c->>'name', 'format', c->>'format', 'headline', c->>'headline', 'primary_text', c->>'primary_text',
           'taken', coalesce(s.build->'posts', '{}') ? (c->>'key') OR coalesce(s.build->'videos', '{}') ? (c->>'key'))
           ORDER BY s.id DESC, c->>'key'), '[]')
    FROM public.ads_meta_strategy s
    JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id
     AND v.version = coalesce(s.approved_version, (SELECT max(version) FROM public.ads_meta_strategy_version x WHERE x.strategy_id = s.id))
   CROSS JOIN jsonb_array_elements(coalesce(v.plan->'creatives', '[]')) c
   WHERE s.status <> 'archived' AND c->>'format' IN ('video', 'image') $$;

-- what one creative did in its ads: spend and Meta leads (insights), leads that became qualified in the CRM
CREATE OR REPLACE FUNCTION crm_private.content_ad_results(p_strategy bigint, p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH ads AS (SELECT st->>'id' ext FROM public.ads_meta_strategy s, jsonb_each(coalesce(s.build->'steps', '{}')) e(k, st)
                WHERE s.id = p_strategy AND k LIKE 'ad:%:' || p_key AND st->>'id' ~ '^[0-9]{3,25}$'),
       d AS (SELECT coalesce(sum(spend), 0) spend, coalesce(sum(leads), 0) leads, min(day) FILTER (WHERE spend > 0) first_day
               FROM public.ads_meta_ad_day WHERE ad_ext IN (SELECT ext FROM ads)),
       q AS (SELECT count(*) FILTER (WHERE x.qualified) qualified, count(*) crm_leads
               FROM public.ads_meta_lead_archive a
               LEFT JOIN (SELECT DISTINCT ON (y.lead_id) y.lead_id, y.qualified FROM crm_private.ads_ad_leads() y ORDER BY y.lead_id, y.created_at) x
                 ON x.lead_id = a.ads_lead_id
              WHERE a.ad_id IN (SELECT ext FROM ads))
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM ads) THEN NULL ELSE jsonb_build_object(
           'ads', (SELECT count(*) FROM ads), 'spend', d.spend, 'leads', greatest(d.leads, q.crm_leads), 'qualified', q.qualified,
           'cpl', CASE WHEN greatest(d.leads, q.crm_leads) > 0 THEN round(d.spend / greatest(d.leads, q.crm_leads)) END, 'first_day', d.first_day) END
    FROM d, q $$;

-- campaign bar: the strategy's campaigns, budget, on/paused and the 7-day learning lock
CREATE OR REPLACE FUNCTION crm_private.content_campaigns() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(z ORDER BY (z->>'strategy_id')::bigint DESC), '[]') FROM (
    SELECT jsonb_build_object('strategy_id', s.id, 'title', s.title, 'status', s.status, 'built', s.build->>'status',
      'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.ext, 'status', o.status, 'name', o.name)), '[]')
                      FROM unnest(crm_private.ads_meta_strategy_campaigns(s)) c(ext)
                      LEFT JOIN public.ads_meta_object o ON o.level = 'campaign' AND o.external_id = c.ext),
      'daily_budget', (SELECT coalesce(sum((cp->>'daily_budget')::numeric) FILTER (WHERE cp->>'budget_level' = 'campaign'), 0)
                            + coalesce(sum((a->>'daily_budget')::numeric) FILTER (WHERE coalesce(cp->>'budget_level', 'adset') <> 'campaign'), 0)
                         FROM jsonb_array_elements(coalesce(v.plan->'campaigns', '[]')) cp
                         LEFT JOIN LATERAL jsonb_array_elements(coalesce(cp->'adsets', '[]')) a ON true
                        WHERE jsonb_typeof(cp->'daily_budget') = 'number' OR jsonb_typeof(a->'daily_budget') = 'number'),
      'videos', (SELECT count(*) FROM jsonb_array_elements(coalesce(v.plan->'creatives', '[]')) c WHERE c->>'format' = 'video'),
      'pictures', (SELECT count(*) FROM jsonb_array_elements(coalesce(v.plan->'creatives', '[]')) c WHERE c->>'format' = 'image'),
      'first_day', f.first_day,
      'learning_day', CASE WHEN f.first_day IS NOT NULL THEN ((now() AT TIME ZONE 'Asia/Kolkata')::date - f.first_day) + 1 END,
      'spend', f.spend, 'leads', f.leads) z
      FROM public.ads_meta_strategy s
      JOIN public.ads_meta_strategy_version v ON v.strategy_id = s.id AND v.version = coalesce(s.approved_version, s.version)
      LEFT JOIN LATERAL (SELECT min(day) FILTER (WHERE spend > 0) first_day, coalesce(sum(spend), 0) spend, coalesce(sum(leads), 0) leads
                           FROM public.ads_meta_ad_day WHERE campaign_ext = ANY (crm_private.ads_meta_strategy_campaigns(s))) f ON true
     WHERE s.status <> 'archived' AND (s.approved_version IS NOT NULL OR coalesce(s.build->>'status', '') <> '')) q(z) $$;

-- the stage an ad is in
CREATE OR REPLACE FUNCTION crm_private.content_stage(i public.content_item) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN i.strategy_id IS NOT NULL AND i.ig ? 'media_id' AND EXISTS (SELECT 1 FROM public.ads_meta_strategy s
           WHERE s.id = i.strategy_id AND s.build->'posts'->i.creative_key->>'ig_media_id' = i.ig->>'media_id') THEN
      CASE WHEN coalesce((crm_private.content_ad_results(i.strategy_id, i.creative_key)->>'spend')::numeric, 0) > 0 THEN 'results' ELSE 'in_ads' END
    WHEN i.ig ? 'media_id' THEN 'posted'
    WHEN i.approved_at IS NOT NULL THEN 'approved'
    WHEN i.media ? 'video_path' OR i.media ? 'path' THEN 'made'
    ELSE 'making' END $$;

-- ------------------------------------------------------------------ overview: ad creatives with stage, caption, Instagram, results
DO $$
BEGIN
  IF to_regprocedure('public.api_content_overview_v118(date)') IS NULL THEN
    ALTER FUNCTION public.api_content_overview(date) RENAME TO api_content_overview_v118;
  END IF;
  IF to_regprocedure('public.api_content_item_save_v118(jsonb)') IS NULL THEN
    ALTER FUNCTION public.api_content_item_save(jsonb) RENAME TO api_content_item_save_v118;
  END IF;
  IF to_regprocedure('public.svc_ads_meta_build_work_v118(bigint)') IS NULL THEN
    ALTER FUNCTION public.svc_ads_meta_build_work(bigint) RENAME TO svc_ads_meta_build_work_v118;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.api_content_overview(p_week date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE o jsonb := public.api_content_overview_v118(p_week);
BEGIN
  RETURN o || jsonb_build_object(
    'ad_creatives', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'source', i.source, 'title', i.title, 'brief', i.brief,
        'status', i.status, 'stage', crm_private.content_stage(i), 'strategy_id', i.strategy_id, 'creative_key', i.creative_key,
        'has_picture', i.media ? 'path', 'paths', coalesce(i.media->'paths', '{}'), 'video', i.media->>'video', 'video_path', i.media->>'video_path',
        'thumb_path', coalesce(i.media->>'thumb_path', i.media->>'path'), 'seconds', i.media->'seconds', 'meta_video', i.media->>'meta_video',
        'caption', coalesce(i.caption, crm_private.content_caption_default(i)), 'caption_saved', i.caption IS NOT NULL,
        'approved_at', i.approved_at, 'post_at', i.post_at, 'post_ai', i.post_ai,
        'ig', i.ig - 'container', 'new_comments', (SELECT count(*) FROM public.content_comment c WHERE c.item_id = i.id AND NOT c.seen AND NOT c.hidden),
        'results', CASE WHEN i.strategy_id IS NOT NULL THEN crm_private.content_ad_results(i.strategy_id, i.creative_key) END,
        'note', i.note, 'updated_at', i.updated_at) ORDER BY i.id DESC), '[]')
      FROM (SELECT * FROM public.content_item WHERE kind IN ('ad_image', 'ad_video') AND status <> 'skipped' ORDER BY id DESC LIMIT 40) i),
    'ad_slots', crm_private.content_ad_slots(),
    'campaigns', crm_private.content_campaigns(),
    'instagram', jsonb_build_object('user_id', nullif(crm_private.ads_cfg('meta_ig_user_id'), ''), 'username', nullif(crm_private.ads_cfg('meta_ig_username'), ''),
      'checked_at', nullif(crm_private.ads_cfg('meta_ig_checked_at'), ''), 'problem', nullif(crm_private.ads_cfg('meta_ig_problem'), '')));
END $$;

-- a first caption from what the ad says (the owner edits it before posting)
CREATE OR REPLACE FUNCTION crm_private.content_caption_default(i public.content_item) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT left(btrim(concat_ws(E'\n\n',
    nullif(coalesce(i.brief->>'primary_text', replace(split_part(coalesce(i.brief->>'script', ''), E'\n', 1) || ' ' || split_part(coalesce(i.brief->>'script', ''), E'\n', 2), '  ', ' ')), ''),
    'Free career counselling at We One Aviation: eligibility and a full roadmap, no commitment.')), 2200) $$;

-- ------------------------------------------------------------------ actions: approve, caption, schedule, use in ads, comments seen
CREATE OR REPLACE FUNCTION public.api_content_item_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.content_item; act text := coalesce(p->>'action', ''); t timestamptz; cap text; sid bigint; k text; fmt text; s public.ads_meta_strategy;
BEGIN
  IF act NOT IN ('approve', 'unapprove', 'caption', 'schedule', 'unschedule', 'use_in_ads', 'remove_from_ads', 'comments_seen', 'retire') THEN
    RETURN public.api_content_item_save_v118(p);
  END IF;
  IF NOT crm_private.ads_can_approve() THEN RAISE EXCEPTION 'Only Admin or ADS approvers can change content' USING ERRCODE = 'PT403'; END IF;
  SELECT * INTO i FROM public.content_item WHERE id = (p->>'id')::bigint FOR UPDATE;
  IF i.id IS NULL OR i.kind NOT IN ('ad_image', 'ad_video') THEN RAISE EXCEPTION 'Pick an ad' USING ERRCODE = 'PT404'; END IF;

  IF act = 'approve' THEN
    IF NOT (i.media ? 'video_path' OR i.media ? 'path') THEN RAISE EXCEPTION 'Reel Studio has not sent this ad yet' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET approved_at = coalesce(approved_at, now()), caption = coalesce(caption, crm_private.content_caption_default(i)),
      updated_at = now() WHERE id = i.id;
  ELSIF act = 'unapprove' THEN
    IF i.ig ? 'media_id' THEN RAISE EXCEPTION 'It is already on Instagram' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET approved_at = NULL, post_at = NULL, updated_at = now() WHERE id = i.id;
  ELSIF act = 'caption' THEN
    IF i.ig ? 'media_id' THEN RAISE EXCEPTION 'It is already on Instagram; edit the caption there' USING ERRCODE = 'PT409'; END IF;
    cap := btrim(coalesce(p->>'caption', ''));
    IF length(cap) < 10 OR length(cap) > 2200 THEN RAISE EXCEPTION 'Caption of 10-2,200 characters (Instagram''s limit)' USING ERRCODE = 'PT422'; END IF;
    IF (SELECT count(*) FROM regexp_matches(cap, '#[[:alnum:]_]+', 'g')) > 30 THEN RAISE EXCEPTION 'At most 30 hashtags (Instagram''s limit)' USING ERRCODE = 'PT422'; END IF;
    UPDATE public.content_item SET caption = cap, updated_at = now() WHERE id = i.id;
  ELSIF act = 'schedule' THEN
    IF i.approved_at IS NULL THEN RAISE EXCEPTION 'Approve it first' USING ERRCODE = 'PT409'; END IF;
    IF i.ig ? 'media_id' THEN RAISE EXCEPTION 'It is already on Instagram' USING ERRCODE = 'PT409'; END IF;
    BEGIN t := (p->>'post_at')::timestamptz; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Pick a date and time' USING ERRCODE = 'PT422'; END;
    IF t IS NULL OR t < now() - interval '2 minutes' THEN RAISE EXCEPTION 'Pick a time from now on' USING ERRCODE = 'PT422'; END IF;
    IF t > now() + interval '75 days' THEN RAISE EXCEPTION 'Pick a time within 75 days' USING ERRCODE = 'PT422'; END IF;
    IF i.kind = 'ad_image' AND coalesce(i.media->>'path', '') !~* '\.jpe?g$' THEN
      RAISE EXCEPTION 'Instagram takes JPEG pictures only; ask Reel Studio for a JPEG version' USING ERRCODE = 'PT409';
    END IF;
    UPDATE public.content_item SET post_at = t, post_ai = coalesce((p->>'ai')::boolean, i.kind = 'ad_video' AND i.source = 'studio'),
      ig = (ig - 'error') || jsonb_build_object('tries', 0), updated_at = now() WHERE id = i.id;
  ELSIF act = 'unschedule' THEN
    IF i.ig ? 'media_id' THEN RAISE EXCEPTION 'It is already on Instagram' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET post_at = NULL, updated_at = now() WHERE id = i.id;
  ELSIF act = 'use_in_ads' THEN
    IF NOT i.ig ? 'media_id' THEN RAISE EXCEPTION 'Post it on Instagram first' USING ERRCODE = 'PT409'; END IF;
    sid := (p->>'strategy_id')::bigint; k := p->>'creative_key';
    fmt := CASE i.kind WHEN 'ad_video' THEN 'video' ELSE 'image' END;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(crm_private.content_ad_slots()) x
                    WHERE (x->>'strategy_id')::bigint = sid AND x->>'key' = k AND x->>'format' = fmt) THEN
      RAISE EXCEPTION 'That strategy has no % ad "%"', CASE fmt WHEN 'video' THEN 'video' ELSE 'picture' END, left(coalesce(k, ''), 40) USING ERRCODE = 'PT422';
    END IF;
    SELECT * INTO s FROM public.ads_meta_strategy WHERE id = sid FOR UPDATE;
    IF EXISTS (SELECT 1 FROM jsonb_each(coalesce(s.build->'steps', '{}')) e(sk, st) WHERE sk LIKE 'creative:' || k || ':%' AND st ? 'id') THEN
      RAISE EXCEPTION 'This ad is already created in Meta; make a new strategy version to change it' USING ERRCODE = 'PT409';
    END IF;
    UPDATE public.content_item SET strategy_id = NULL, creative_key = NULL, updated_at = now()
     WHERE strategy_id = sid AND creative_key = k AND kind = i.kind AND id <> i.id;
    UPDATE public.content_item SET strategy_id = sid, creative_key = k, updated_at = now() WHERE id = i.id;
    UPDATE public.ads_meta_strategy SET build = jsonb_set(coalesce(build, '{}') || jsonb_build_object('posts', coalesce(build->'posts', '{}')),
        ARRAY['posts', k], jsonb_build_object('ig_media_id', i.ig->>'media_id', 'item', i.id, 'permalink', i.ig->>'permalink', 'at', now())),
      updated_at = now() WHERE id = sid;
  ELSIF act = 'remove_from_ads' THEN
    IF i.strategy_id IS NOT NULL THEN
      UPDATE public.ads_meta_strategy SET build = build #- ARRAY['posts', i.creative_key], updated_at = now()
       WHERE id = i.strategy_id AND build->'posts'->i.creative_key->>'item' = i.id::text;
    END IF;
    UPDATE public.content_item SET strategy_id = NULL, creative_key = NULL, updated_at = now() WHERE id = i.id;
  ELSIF act = 'comments_seen' THEN
    UPDATE public.content_comment SET seen = true WHERE item_id = i.id AND NOT seen;
  ELSIF act = 'retire' THEN
    IF i.ig ? 'media_id' THEN RAISE EXCEPTION 'It is on Instagram; remove it from ads instead' USING ERRCODE = 'PT409'; END IF;
    UPDATE public.content_item SET status = 'skipped', post_at = NULL, updated_at = now() WHERE id = i.id;
  END IF;
  RETURN jsonb_build_object('id', i.id, 'stage', crm_private.content_stage((SELECT x FROM public.content_item x WHERE x.id = i.id)));
END $$;

CREATE OR REPLACE FUNCTION public.api_content_comments(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM crm_private.ads_require_view();
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.ig_id, 'username', c.username, 'body', c.body, 'at', c.at, 'seen', c.seen,
            'hidden', c.hidden, 'reply', c.reply, 'replied_at', c.replied_at) ORDER BY c.at DESC NULLS LAST), '[]')
            FROM public.content_comment c WHERE c.item_id = p_id);
END $$;

-- ------------------------------------------------------------------ ads-sync (service role)
-- what is due: posts whose time has come (at most 3 tries) and posted items whose numbers are over an hour old
CREATE OR REPLACE FUNCTION public.svc_content_ig_due() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'ig_user_id', nullif(crm_private.ads_cfg('meta_ig_user_id'), ''),
    'page_id', nullif(crm_private.ads_cfg('meta_page_id'), ''),
    'post', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'caption', coalesce(i.caption, crm_private.content_caption_default(i)),
               'ai', i.post_ai, 'video_path', i.media->>'video_path', 'thumb_path', i.media->>'thumb_path', 'path', i.media->>'path',
               'container', i.ig->>'container', 'tries', coalesce((i.ig->>'tries')::int, 0)) ORDER BY i.post_at), '[]')
               FROM (SELECT * FROM public.content_item WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                       AND coalesce((ig->>'tries')::int, 0) < 3 AND kind IN ('ad_image', 'ad_video') ORDER BY post_at LIMIT 3) i),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'media_id', i.ig->>'media_id', 'kind', i.kind)), '[]')
                FROM (SELECT * FROM public.content_item WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                        AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes' ORDER BY id LIMIT 12) i)) $$;

CREATE OR REPLACE FUNCTION crm_private.content_ig_wake() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.content_item WHERE post_at <= now() AND approved_at IS NOT NULL AND NOT ig ? 'media_id'
                   AND coalesce((ig->>'tries')::int, 0) < 3)
      OR EXISTS (SELECT 1 FROM public.content_item WHERE ig ? 'media_id' AND (ig->>'posted_at')::timestamptz > now() - interval '45 days'
                   AND coalesce((ig->>'stats_at')::timestamptz, 'epoch') < now() - interval '55 minutes') $$;

CREATE OR REPLACE FUNCTION public.svc_content_ig_account(p_user_id text, p_username text, p_problem text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.ads_config (key, value) VALUES
    ('meta_ig_user_id', coalesce(CASE WHEN p_user_id ~ '^[0-9]{5,30}$' THEN p_user_id END, '')),
    ('meta_ig_username', left(coalesce(p_username, ''), 60)), ('meta_ig_problem', left(coalesce(p_problem, ''), 300)),
    ('meta_ig_checked_at', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION public.svc_content_ig_step(p_id bigint, p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p ? 'media_id' THEN                                   -- published
    UPDATE public.content_item SET ig = (ig - 'container' - 'error') || jsonb_build_object('media_id', p->>'media_id', 'permalink', p->>'permalink',
        'posted_at', now(), 'ai', p->'ai'), status = 'posted', slot = now(), updated_at = now() WHERE id = p_id;
  ELSIF p ? 'container' THEN                               -- container made, Instagram still processing the video
    UPDATE public.content_item SET ig = ig || jsonb_build_object('container', p->>'container'), updated_at = now() WHERE id = p_id;
  ELSIF p ? 'error' THEN                                   -- a failed try; after 3 the post waits for the owner
    UPDATE public.content_item SET ig = (ig - 'container') || jsonb_build_object('error', left(p->>'error', 300), 'tries', coalesce((ig->>'tries')::int, 0) + 1),
      post_at = CASE WHEN coalesce((ig->>'tries')::int, 0) + 1 >= 3 THEN NULL ELSE post_at END,
      note = CASE WHEN coalesce((ig->>'tries')::int, 0) + 1 >= 3 THEN 'Instagram did not take it: ' || left(p->>'error', 200) ELSE note END,
      updated_at = now() WHERE id = p_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.svc_content_ig_stats(p_id bigint, p_stats jsonb, p_comments jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE st jsonb := '{}'; k text;
BEGIN
  FOREACH k IN ARRAY ARRAY['views', 'reach', 'likes', 'saves', 'shares', 'comments'] LOOP
    IF jsonb_typeof(p_stats->k) = 'number' THEN st := st || jsonb_build_object(k, (p_stats->>k)::bigint); END IF;
  END LOOP;
  UPDATE public.content_item SET ig = ig || jsonb_build_object('stats', st, 'stats_at', now()), stats = stats || st WHERE id = p_id;
  INSERT INTO public.content_comment (ig_id, item_id, username, body, at)
  SELECT c->>'id', p_id, left(c->>'username', 60), left(c->>'text', 2200), (c->>'timestamp')::timestamptz
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_comments) = 'array' THEN p_comments ELSE '[]' END) c
   WHERE c->>'id' ~ '^[0-9]{3,30}$'
  ON CONFLICT (ig_id) DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.svc_content_comment_get(p_ig_id text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id', c.ig_id, 'item_id', c.item_id, 'hidden', c.hidden, 'reply', c.reply) FROM public.content_comment c WHERE c.ig_id = p_ig_id $$;

CREATE OR REPLACE FUNCTION public.svc_content_comment_done(p_ig_id text, p_action text, p_text text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.content_comment SET seen = true,
    hidden = CASE p_action WHEN 'hide' THEN true WHEN 'unhide' THEN false ELSE hidden END,
    reply = CASE WHEN p_action = 'reply' THEN left(p_text, 2200) ELSE reply END,
    replied_at = CASE WHEN p_action = 'reply' THEN now() ELSE replied_at END
   WHERE ig_id = p_ig_id;
END $$;

-- Create in Meta: the posts chosen for each ad slot, and the Instagram account they live on
CREATE OR REPLACE FUNCTION public.svc_ads_meta_build_work(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w jsonb := public.svc_ads_meta_build_work_v118(p_id);
BEGIN
  IF w IS NULL THEN RETURN NULL; END IF;
  RETURN w || jsonb_build_object('posts', coalesce((SELECT build->'posts' FROM public.ads_meta_strategy WHERE id = p_id), '{}'),
                                 'ig_user_id', nullif(crm_private.ads_cfg('meta_ig_user_id'), ''));
END $$;

-- ------------------------------------------------------------------ grants
REVOKE ALL ON FUNCTION public.svc_content_ig_due(), public.svc_content_ig_account(text, text, text), public.svc_content_ig_step(bigint, jsonb),
  public.svc_content_ig_stats(bigint, jsonb, jsonb), public.svc_content_comment_get(text), public.svc_content_comment_done(text, text, text),
  public.svc_ads_meta_build_work(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_content_ig_due(), public.svc_content_ig_account(text, text, text), public.svc_content_ig_step(bigint, jsonb),
  public.svc_content_ig_stats(bigint, jsonb, jsonb), public.svc_content_comment_get(text), public.svc_content_comment_done(text, text, text),
  public.svc_ads_meta_build_work(bigint) TO service_role;
REVOKE ALL ON FUNCTION crm_private.content_ad_slots(), crm_private.content_ad_results(bigint, text), crm_private.content_campaigns(),
  crm_private.content_stage(public.content_item), crm_private.content_caption_default(public.content_item), crm_private.content_ig_wake() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_content_overview(date), public.api_content_item_save(jsonb), public.api_content_comments(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_content_overview(date), public.api_content_item_save(jsonb), public.api_content_comments(bigint) TO authenticated;

-- ------------------------------------------------------------------ the clock: every 5 minutes, only when something is due
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'crm-content-ig';
    PERFORM cron.schedule('crm-content-ig', '*/5 * * * *', $job$
      SELECT net.http_post(
        url := 'https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-sync',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'crm_cron_token')),
        body := '{"jobs": ["ig_due"]}'::jsonb, timeout_milliseconds := 140000)
      WHERE crm_private.content_ig_wake()
    $job$);
  END IF;
END $$;

INSERT INTO public.ads_config (key, value) VALUES ('ads_schema', '119') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
