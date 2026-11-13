#!/usr/bin/env bash
# Runs the ADS SQL tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=ads_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
for f in ../amazon/00_supabase_stub.sql 01_ads_stub.sql $M/076_ads_module.sql $M/078_ads_client_wizard.sql $M/092_ads_google_ops.sql $M/093_ads_autopilot.sql $M/094_ads_agents.sql $M/076_ads_module.sql $M/078_ads_client_wizard.sql $M/092_ads_google_ops.sql $M/093_ads_autopilot.sql $M/094_ads_agents.sql; do   # twice: must be re-runnable
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
cat 10_ads_tests.sql 20_ads_wizard_tests.sql 30_ads_google_ops_tests.sql 40_ads_autopilot_tests.sql 50_ads_agents_tests.sql | psql -X -q -t -v ON_ERROR_STOP=1 -d $DB 2>&1 | grep -E "PASS|FAIL|ERROR|ALL ADS" | sed 's/^.*NOTICE:  //'
