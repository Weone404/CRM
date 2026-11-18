#!/usr/bin/env bash
# 111 Connections & keys: throwaway database with the ADS and Amazon modules, then the vault overview.
# Needs PGHOST/PGUSER(/PGPASSWORD) for a local Postgres.
set -euo pipefail
cd "$(dirname "$0")"
DB=vault_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
ADS="076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 100_ads_meta_signals 101_ads_meta_organic 102_ads_meta_verification 103_ads_meta_insights 104_ads_meta_strategy 105_ads_meta_reports 106_ads_meta_quality 107_ads_meta_funnel 108_ads_site_signals 109_ads_meta_funnel_plan 110_ads_meta_actions"
AMZ="072_amazon_module 073_amazon_seed 075_amazon_dispatch 076_amazon_product_editor 077_amazon_legal_soft 078_amazon_decisions_chat 080_amazon_fixall_alerts 081_amazon_personal 082_amazon_notify 083_amazon_market_keywords 084_amazon_keyword_quality 085_amazon_keyword_smart 086_amazon_studio 087_amazon_studio_design 088_amazon_studio_scenes"
FILES="../amazon/00_supabase_stub.sql ../ads/01_ads_stub.sql 05_vault_stub.sql"
for m in $ADS $AMZ; do FILES="$FILES $M/$m.sql"; done
FILES="$FILES $M/111_crm_vault.sql $M/111_crm_vault.sql"     # twice: must be re-runnable
for f in $FILES; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_vault_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL VAULT" | sed 's/^.*NOTICE:  //'
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/111_crm_vault_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.api_vault_overview()') IS NULL AND (SELECT count(*) FROM vault.secrets) > 0" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/111_crm_vault.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.api_vault_overview()') IS NOT NULL" | grep -q "^t$" \
  && echo "PASS VR1 111 rolls back without touching any key, and re-applies" || echo "FAIL VR1 111 rollback"
