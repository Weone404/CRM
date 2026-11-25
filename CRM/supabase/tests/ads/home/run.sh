#!/usr/bin/env bash
# 146 ADS Google Ads home (balance from Google, one daily amount, the home read): throwaway database with the Google side of ADS
# (076-099), 142, 144, 145, then 146 twice. Needs PGHOST/PGUSER(/PGPASSWORD).
set -euo pipefail
cd "$(dirname "$0")"
DB=ads_home_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../../backend/migrations
FILES="../../amazon/00_supabase_stub.sql ../01_ads_stub.sql"
for m in 076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team 142_ads_delivery_watch 144_ads_google_premium 145_ads_google_schedule; do FILES="$FILES $M/$m.sql"; done
for f in $FILES 00_before.sql $M/146_ads_google_home.sql $M/146_ads_google_home.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 -A3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_home_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL " | sed 's/^.*NOTICE:  //'
# rollback: refused while budget_set operations exist; then back to 145 (budget_set unknown, schedules intact); then re-applies
{ psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/146_ads_google_home_down.sql 2>&1 || true; } | grep -q "cannot be rolled back" \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.api_ads_google_home(int)') IS NOT NULL AND to_regclass('public.ads_google_balance') IS NOT NULL" | grep -q "^t$" \
  && echo "PASS HR1 rollback is refused while budget changes exist (nothing half-removed)" || echo "FAIL HR1 rollback refusal"
psql -q -X -d $DB -c "DELETE FROM public.ads_google_ops WHERE kind = 'budget_set'" >/dev/null
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/146_ads_google_home_down.sql >/dev/null 2>&1 \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/145_ads_google_schedule.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('crm_private.ads_google_gate_v145(uuid,text,jsonb,uuid)') IS NULL AND to_regprocedure('public.api_ads_google_home(int)') IS NULL AND to_regclass('public.ads_google_balance') IS NULL AND (crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google' LIMIT 1), 'budget_set', '{}')->'blockers') @> '[\"Unknown operation type.\"]' AND jsonb_array_length(crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google' LIMIT 1), 'ad_schedule', '{\"campaign_id\":\"1\",\"slots\":[{\"start_hour\":0,\"end_hour\":24}]}')->'blockers') = 0 AND (SELECT value FROM public.ads_config WHERE key = 'google_cap_daily') IS NOT NULL" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/146_ads_google_home.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('public.api_ads_google_home(int)') IS NOT NULL AND NOT (crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google' LIMIT 1), 'budget_set', '{}')->'blockers') @> '[\"Unknown operation type.\"]'" | grep -q "^t$" \
  && echo "PASS HR2 146 rolls back to 145 (budget_set unknown, schedules intact, the owner's limits kept) and re-applies" || echo "FAIL HR2 146 rollback"
