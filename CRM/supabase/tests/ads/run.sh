#!/usr/bin/env bash
# Runs the ADS SQL tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=ads_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
for f in ../amazon/00_supabase_stub.sql 01_ads_stub.sql $M/076_ads_module.sql $M/078_ads_client_wizard.sql $M/089_ads_leads_phase1.sql $M/090_ads_leads_board.sql $M/091_ads_campaign_delivery.sql $M/092_ads_google_ops.sql $M/093_ads_autopilot.sql $M/094_ads_agents.sql $M/095_ads_hardening.sql $M/096_ads_supervisor.sql $M/097_ads_today.sql $M/098_ads_lead_attribution.sql $M/099_ads_team.sql $M/100_ads_meta_signals.sql $M/101_ads_meta_organic.sql $M/076_ads_module.sql $M/078_ads_client_wizard.sql $M/089_ads_leads_phase1.sql $M/090_ads_leads_board.sql $M/091_ads_campaign_delivery.sql $M/092_ads_google_ops.sql $M/093_ads_autopilot.sql $M/094_ads_agents.sql $M/095_ads_hardening.sql $M/096_ads_supervisor.sql $M/097_ads_today.sql $M/098_ads_lead_attribution.sql $M/099_ads_team.sql $M/100_ads_meta_signals.sql $M/101_ads_meta_organic.sql; do   # twice: must be re-runnable
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
cat 10_ads_tests.sql 20_ads_wizard_tests.sql 30_ads_google_ops_tests.sql 40_ads_autopilot_tests.sql 50_ads_agents_tests.sql 60_ads_hardening_tests.sql 70_ads_supervisor_tests.sql 80_ads_attribution_tests.sql 90_ads_team_tests.sql A0_ads_meta_tests.sql A1_ads_meta_organic_tests.sql | psql -X -q -t -v ON_ERROR_STOP=1 -d $DB 2>&1 | grep -E "PASS|FAIL|ERROR|ALL ADS" | sed 's/^.*NOTICE:  //'
# 101 must roll back (no organic_lead_id, test rows back to organic, no schema mark) and re-apply cleanly.
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/101_ads_meta_organic_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -v ON_ERROR_STOP=1 -d $DB -c "SELECT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'ads_meta_lead_raw' AND column_name = 'organic_lead_id'), NOT EXISTS (SELECT 1 FROM public.ads_meta_lead_raw WHERE status = 'test'), NOT EXISTS (SELECT 1 FROM public.ads_config WHERE key = 'ads_schema')" 2>&1 | grep -q "^t|t|t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/101_ads_meta_organic.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -v ON_ERROR_STOP=1 -d $DB -c "SELECT value FROM public.ads_config WHERE key = 'ads_schema'" 2>&1 | grep -q "^101$" \
  && echo "PASS R04 101 rolls back and re-applies" || echo "FAIL R04 101 rollback"
# 100 must roll back (no Meta tables, old secret list) and re-apply cleanly.
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/100_ads_meta_signals_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -v ON_ERROR_STOP=1 -d $DB -c "SELECT to_regclass('public.ads_meta_settings') IS NULL, to_regproc('public.svc_ads_meta_capi_work') IS NULL, array_length(crm_private.ads_secret_names(), 1), to_regprocedure('public.api_ads_lead_board(text,text,boolean,text,integer)') IS NOT NULL" 2>&1 | grep -q "^t|t|8|t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/100_ads_meta_signals.sql >/dev/null 2>&1 \
  && psql -q -X -t -v ON_ERROR_STOP=1 -d $DB -c "SELECT count(*) FROM public.ads_meta_event_map" 2>&1 | grep -q "39" \
  && echo "PASS R03 100 rolls back and re-applies" || echo "FAIL R03 100 rollback"
# 099 must roll back (old scheduler, old gate, no team tables) and re-apply cleanly.
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/099_ads_team_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -A -v ON_ERROR_STOP=1 -d $DB -c "SELECT public.svc_ads_agents_tick() ? 'started', to_regclass('public.ads_agent_desks') IS NULL, to_regproc('public.svc_ads_suggestions_auto') IS NULL" 2>&1 | grep -q "^t|t|t$" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/099_ads_team.sql >/dev/null 2>&1 \
  && psql -q -X -t -v ON_ERROR_STOP=1 -d $DB -c "SELECT count(*) FROM public.ads_agent_desks" 2>&1 | grep -q "14" \
  && echo "PASS R02 099 rolls back to the old definitions and re-applies" || echo "FAIL R02 099 rollback"
# 098 must roll back to the previous definitions and re-apply cleanly.
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/098_ads_lead_attribution_down.sql >/dev/null 2>&1 \
  && psql -q -X -t -v ON_ERROR_STOP=1 -d $DB -c "SELECT crm_private.ads_report_data(current_date)->>'crm_leads', to_regproc('crm_private.ads_ad_leads') IS NULL" 2>&1 | grep -q "| t" \
  && psql -q -X -v ON_ERROR_STOP=1 -d $DB -f $M/098_ads_lead_attribution.sql >/dev/null 2>&1 \
  && echo "PASS R01 098 rolls back to the old definitions and re-applies" || echo "FAIL R01 098 rollback"
