#!/usr/bin/env bash
# 112 CRM > Website: throwaway database with the ADS module, then the Website tables and insights. Needs PGHOST/PGUSER(/PGPASSWORD).
set -euo pipefail
cd "$(dirname "$0")"
DB=web_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
ADS="076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 100_ads_meta_signals 101_ads_meta_organic 102_ads_meta_verification 103_ads_meta_insights 104_ads_meta_strategy 105_ads_meta_reports 106_ads_meta_quality 107_ads_meta_funnel 108_ads_site_signals 109_ads_meta_funnel_plan 110_ads_meta_actions"
FILES="../amazon/00_supabase_stub.sql ../ads/01_ads_stub.sql"
for m in $ADS; do FILES="$FILES $M/$m.sql"; done
FILES="$FILES $M/112_crm_website.sql $M/112_crm_website.sql"     # twice: must be re-runnable
for f in $FILES; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_website_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL WEBSITE" | sed 's/^.*NOTICE:  //'
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/112_crm_website_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regclass('public.web_row') IS NULL AND to_regprocedure('public.api_web_overview()') IS NULL AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'ads_google_site_refresh_token')" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/112_crm_website.sql >/dev/null 2>&1 \
  && echo "PASS WR1 112 rolls back (keeps the Google sign-in) and re-applies" || echo "FAIL WR1 112 rollback"
