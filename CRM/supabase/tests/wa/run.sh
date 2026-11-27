#!/usr/bin/env bash
# Runs the WhatsApp SQL tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=wa_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
for f in ../amazon/00_supabase_stub.sql 01_wa_stub.sql ../../../backend/migrations/150_whatsapp.sql \
         ../../../backend/migrations/150_whatsapp.sql; do   # 150 twice: must be re-runnable
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_wa_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL SQL" | sed 's/^.*NOTICE:  //'
# The down migration removes everything WhatsApp added and leaves Leads untouched.
psql -q -X -v ON_ERROR_STOP=1 -d $DB -f ../../../backend/migrations/150_whatsapp_down.sql >/dev/null 2>&1 || { echo "FAILED down migration"; exit 1; }
psql -X -q -t -d $DB -c "SELECT CASE WHEN to_regclass('public.wa_contact') IS NULL AND to_regclass('public.lead') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('wa_lead_in', 'wa_ads_lead_in')) THEN 'PASS W95 down migration removes WhatsApp, keeps Leads' ELSE 'FAIL W95 down migration' END"
