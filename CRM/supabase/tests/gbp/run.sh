#!/usr/bin/env bash
# 139 CRM > Google > Google My Business: throwaway database with the ADS and Website modules, then the gbp_* tables. Needs PGHOST/PGUSER(/PGPASSWORD).
set -euo pipefail
cd "$(dirname "$0")"
DB=gbp_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
ADS="076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 100_ads_meta_signals 101_ads_meta_organic 102_ads_meta_verification 103_ads_meta_insights 104_ads_meta_strategy 105_ads_meta_reports 106_ads_meta_quality 107_ads_meta_funnel 108_ads_site_signals 109_ads_meta_funnel_plan 110_ads_meta_actions"
FILES="../amazon/00_supabase_stub.sql ../ads/01_ads_stub.sql"
for m in $ADS; do FILES="$FILES $M/$m.sql"; done
FILES="$FILES $M/112_crm_website.sql $M/113_crm_website_trend.sql $M/139_crm_google_business.sql $M/139_crm_google_business.sql $M/140_crm_gbp_replies.sql $M/140_crm_gbp_replies.sql $M/141_crm_gbp_replies_off.sql $M/141_crm_gbp_replies_off.sql $M/143_crm_gbp_profile_posts_photos.sql $M/143_crm_gbp_profile_posts_photos.sql"     # twice: must be re-runnable
for f in $FILES; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_gbp_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL GBP" | sed 's/^.*NOTICE:  //'
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 20_gbp_reply_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL GBP" | sed 's/^.*NOTICE:  //'
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 30_gbp_profile_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL GBP" | sed 's/^.*NOTICE:  //'
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/143_crm_gbp_profile_posts_photos_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regclass('public.gbp_post') IS NULL AND to_regclass('public.gbp_media') IS NULL AND to_regclass('public.gbp_post_out') IS NULL AND to_regclass('public.gbp_review') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'gbp_location' AND column_name IN ('details', 'extras_at', 'media_owner'))
       AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('gbp_health', 'api_gbp_profile', 'api_gbp_posts', 'api_gbp_media', 'api_gbp_post_create', 'svc_gbp_post_queue')) AND jsonb_typeof(public.svc_gbp_work()) = 'object'" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/143_crm_gbp_profile_posts_photos.sql >/dev/null 2>&1 \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/143_crm_gbp_profile_posts_photos_down.sql >/dev/null 2>&1 \
  && echo "PASS GR000 143 rolls back on its own (reviews, numbers and the rest stay), re-applies and rolls back again" || echo "FAIL GR000 143 rollback"
psql -q -X -t -A -d $DB -c "UPDATE public.gbp_config SET value = 'on' WHERE key = 'reply_enabled'" >/dev/null
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/141_crm_gbp_replies_off.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT value = 'on' FROM public.gbp_config WHERE key = 'reply_enabled'" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/141_crm_gbp_replies_off_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT NOT EXISTS (SELECT 1 FROM public.gbp_config WHERE key = 'reply_enabled') AND to_regclass('public.gbp_reply') IS NOT NULL
       AND pg_get_functiondef('public.svc_gbp_reply_queue(int)'::regprocedure) NOT LIKE '%reply_enabled%' AND pg_get_functiondef('public.api_gbp_reply_status()'::regprocedure) NOT LIKE '%reply_enabled%'" | grep -q "^t$" \
  && echo "PASS GR00 141 does not switch replies off again once someone has switched them on; it rolls back to 140 as it was" || echo "FAIL GR00 141 re-run / rollback"
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/140_crm_gbp_replies_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regclass('public.gbp_reply') IS NULL AND to_regclass('public.gbp_config') IS NULL AND to_regclass('public.gbp_review') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname LIKE '%gbp_reply%' OR proname = 'gbp_cfg') AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_gbp_review_changed')
       AND pg_get_functiondef('public.api_gbp_reviews(uuid, text, int)'::regprocedure) NOT LIKE '%gbp_reply%'" | grep -q "^t$" \
  && echo "PASS GR0 140 rolls back on its own: replies go, reviews and the 139 screen stay" || echo "FAIL GR0 140 rollback"
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/140_crm_gbp_replies.sql >/dev/null 2>&1 || echo "FAIL GR0 140 re-apply"
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/140_crm_gbp_replies_down.sql >/dev/null 2>&1
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/139_crm_google_business_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regclass('public.gbp_connection') IS NULL AND to_regprocedure('public.api_google_hub()') IS NULL
       AND NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name LIKE 'crm\_gbp\_%') AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'ads_google_ads_client_id')
       AND to_regprocedure('public.api_web_overview()') IS NOT NULL AND to_regclass('public.ads_campaigns') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname LIKE '%gbp%')" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/139_crm_google_business.sql >/dev/null 2>&1 && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/140_crm_gbp_replies.sql >/dev/null 2>&1 \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/141_crm_gbp_replies_off.sql >/dev/null 2>&1 && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/143_crm_gbp_profile_posts_photos.sql >/dev/null 2>&1 \
  && echo "PASS GR1 139 rolls back (its tokens go, the Google sign-in, Website and Ads stay) and re-applies" || echo "FAIL GR1 139 rollback"
# Without the ADS and Website modules it still installs and works for Admin (the hub cards for the missing modules are empty).
DB2=gbp_bare_$$
psql -q -c "CREATE DATABASE $DB2" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null; psql -q -c "DROP DATABASE IF EXISTS $DB2" >/dev/null' EXIT
psql -q -X -v ON_ERROR_STOP=1 -d $DB2 -f ../amazon/00_supabase_stub.sql >/dev/null 2>&1 && psql -q -X -v ON_ERROR_STOP=1 -d $DB2 -f $M/139_crm_google_business.sql >/dev/null 2>&1 && psql -q -X -v ON_ERROR_STOP=1 -d $DB2 -f $M/140_crm_gbp_replies.sql >/dev/null 2>&1 \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB2 -f $M/141_crm_gbp_replies_off.sql >/dev/null 2>&1 && psql -q -X -v ON_ERROR_STOP=1 -d $DB2 -f $M/143_crm_gbp_profile_posts_photos.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB2 -c "INSERT INTO public.employee (id, name, department, auth_user_id) VALUES ('00000000-0000-0000-0000-00000000000a', 'A', 'Admin', '10000000-0000-0000-0000-00000000000a'),
       ('00000000-0000-0000-0000-00000000000b', 'B', 'Sales', '10000000-0000-0000-0000-00000000000b');
     SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', false);
     SET ROLE authenticated;
     SELECT (h->'website') = 'null'::jsonb AND (h->'ads') = 'null'::jsonb AND (h->'gbp'->>'tracked')::int = 0 AND (public.api_gbp_overview()->'setup'->>'client')::boolean IS FALSE AND public.api_gbp_reply_status()->'helper_seen' = 'null'::jsonb AND public.api_gbp_reply_status()->'enabled' = 'false'::jsonb AND public.api_gbp_profile() = '[]'::jsonb AND public.api_gbp_posts()->'posts' = '[]'::jsonb
       FROM (SELECT public.api_google_hub() h) z" | tail -1 | grep -q "^t$" \
  && echo "PASS GR2 installs on its own: Admin sees an empty hub, nothing breaks without the Ads and Website modules" || echo "FAIL GR2 standalone install"
