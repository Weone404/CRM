#!/usr/bin/env bash
# 142 ADS delivery watch: throwaway database with the Google side of ADS (076-099), then 142 twice. Needs PGHOST/PGUSER(/PGPASSWORD).
set -euo pipefail
cd "$(dirname "$0")"
DB=ads_delivery_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../../backend/migrations
FILES="../../amazon/00_supabase_stub.sql ../01_ads_stub.sql"
for m in 076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 142_ads_delivery_watch 142_ads_delivery_watch; do FILES="$FILES $M/$m.sql"; done
for f in $FILES; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_delivery_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL |^ *[0-9]" | sed 's/^.*NOTICE:  //'
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/142_ads_delivery_watch_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.api_ads_delivery()') IS NULL AND to_regprocedure('crm_private.ads_google_delivery()') IS NULL AND to_regprocedure('public.api_ads_autopilot()') IS NOT NULL" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/142_ads_delivery_watch.sql >/dev/null 2>&1 \
  && echo "PASS DR1 142 rolls back (the rest of ADS untouched) and re-applies" || echo "FAIL DR1 142 rollback"
