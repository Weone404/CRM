#!/usr/bin/env bash
# 144 + 145 ADS premium targeting and time-of-day bids: throwaway database with the Google side of ADS (076-099), 144 twice, then 145 twice. Needs PGHOST/PGUSER(/PGPASSWORD).
set -euo pipefail
cd "$(dirname "$0")"
DB=ads_premium_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../../backend/migrations
FILES="../../amazon/00_supabase_stub.sql ../01_ads_stub.sql"
for m in 076_ads_module 078_ads_client_wizard 089_ads_leads_phase1 090_ads_leads_board 091_ads_campaign_delivery 092_ads_google_ops 093_ads_autopilot 094_ads_agents 095_ads_hardening 096_ads_supervisor 097_ads_today 098_ads_lead_attribution 099_ads_team; do FILES="$FILES $M/$m.sql"; done
for f in $FILES 00_before.sql $M/144_ads_google_premium.sql $M/144_ads_google_premium.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_premium_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL |^ *[0-9]" | sed 's/^.*NOTICE:  //'
# rollback: refused while new-kind operations exist; then clean, with the old gate back under its own name; then re-applies
{ psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/144_ads_google_premium_down.sql 2>&1 || true; } | grep -q "cannot be rolled back" \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('crm_private.ads_google_gate_v143(uuid,text,jsonb,uuid)') IS NOT NULL" | grep -q "^t$" \
  && echo "PASS PR1 rollback is refused while operations of the new kinds exist (nothing half-removed)" || echo "FAIL PR1 rollback refusal"
psql -q -X -d $DB -c "DELETE FROM public.ads_google_ops WHERE kind IN ('campaign_create', 'income_filter')" >/dev/null
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/144_ads_google_premium_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('crm_private.ads_google_gate_v143(uuid,text,jsonb,uuid)') IS NULL AND to_regprocedure('crm_private.ads_google_gate(uuid,text,jsonb,uuid)') IS NOT NULL AND to_regprocedure('public.svc_ads_google_build_work()') IS NULL AND (crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google'), 'campaign_create', '{}')->'blockers') @> '[\"Unknown operation type.\"]' AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_ads_google_ops_owner_only')" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/144_ads_google_premium.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT jsonb_array_length(crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google'), 'income_filter', '{\"campaign_id\":\"1\",\"exclude\":[\"INCOME_RANGE_0_50\"]}')->'blockers') = 0" | grep -q "^t$" \
  && echo "PASS PR2 144 rolls back (old gate under its own name, new kinds unknown again) and re-applies" || echo "FAIL PR2 144 rollback"
# 145 on top: twice, its tests, then rollback (refused while schedule operations exist) and re-apply
for f in $M/145_ads_google_schedule.sql $M/145_ads_google_schedule.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 20_schedule_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL |^ *[0-9]" | sed 's/^.*NOTICE:  //'
{ psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/145_ads_google_schedule_down.sql 2>&1 || true; } | grep -q "cannot be rolled back" \
  && psql -q -X -d $DB -c "DELETE FROM public.ads_google_ops WHERE kind = 'ad_schedule'" >/dev/null \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/145_ads_google_schedule_down.sql >/dev/null 2>&1 \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/144_ads_google_premium.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT to_regprocedure('crm_private.ads_google_gate_v144(uuid,text,jsonb,uuid)') IS NULL AND (crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google'), 'ad_schedule', '{}')->'blockers') @> '[\"Unknown operation type.\"]' AND jsonb_array_length(crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google'), 'income_filter', '{\"campaign_id\":\"1\",\"exclude\":[\"INCOME_RANGE_0_50\"]}')->'blockers') = 0" | grep -q "^t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/145_ads_google_schedule.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -d $DB -c "SELECT jsonb_array_length(crm_private.ads_google_gate((SELECT id FROM public.ads_accounts WHERE platform = 'google'), 'ad_schedule', '{\"campaign_id\":\"1\",\"slots\":[{\"start_hour\":0,\"end_hour\":24}]}')->'blockers') = 0" | grep -q "^t$" \
  && echo "PASS PR3 145 rollback is refused while schedules exist, then rolls back to 144 (schedules unknown, income filter intact) and re-applies" || echo "FAIL PR3 145 rollback"
