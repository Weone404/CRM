#!/usr/bin/env bash
# 116 Growth > Content: throwaway database with ADS (incl. 114-115), the vault (111) and Website (112), then content.
# Needs PGHOST/PGUSER(/PGPASSWORD) for a local Postgres.
set -euo pipefail
cd "$(dirname "$0")"
DB=content_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
ADS="076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 100_ads_meta_signals 101_ads_meta_organic 102_ads_meta_verification 103_ads_meta_insights 104_ads_meta_strategy 105_ads_meta_reports 106_ads_meta_quality 107_ads_meta_funnel 108_ads_site_signals 109_ads_meta_funnel_plan 110_ads_meta_actions 114_ads_meta_premium 115_ads_competitors"
FILES="../amazon/00_supabase_stub.sql ../ads/01_ads_stub.sql ../vault/05_vault_stub.sql 05_content_stub.sql"
for m in $ADS; do FILES="$FILES $M/$m.sql"; done
FILES="$FILES $M/111_crm_vault.sql $M/112_crm_website.sql $M/116_crm_content.sql $M/116_crm_content.sql $M/117_crm_ad_videos.sql $M/117_crm_ad_videos.sql"     # twice: must be re-runnable
for f in $FILES; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_content_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL CONTENT" | sed 's/^.*NOTICE:  //'
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 20_video_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL VIDEO" | sed 's/^.*NOTICE:  //'
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/117_crm_ad_videos_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.svc_ads_meta_build_work_v116(bigint)') IS NULL AND to_regprocedure('public.api_content_overview(date)') IS NOT NULL AND to_regprocedure('public.svc_content_adopt(jsonb)') IS NULL AND NOT EXISTS (SELECT 1 FROM public.content_item WHERE source = 'studio')" | grep -q "^t$" \
  && echo "PASS CR2 117 rolls back to 116" || echo "FAIL CR2 117 rollback"
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/116_crm_content_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regclass('public.content_item') IS NULL AND to_regprocedure('public.svc_ads_agent_next2_v104(boolean)') IS NULL AND to_regprocedure('public.svc_ads_agent_next2(boolean)') IS NOT NULL AND to_regprocedure('public.api_vault_overview_v111()') IS NULL AND to_regprocedure('public.api_vault_overview()') IS NOT NULL" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/116_crm_content.sql >/dev/null 2>&1 \
  && echo "PASS CR1 116 rolls back (agent queue and vault restored) and re-applies" || echo "FAIL CR1 116 rollback"
