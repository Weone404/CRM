#!/usr/bin/env bash
# Runs the Amazon SQL tests on a throwaway local Postgres database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=amz_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
for f in 00_supabase_stub.sql ../../../backend/migrations/072_amazon_module.sql ../../../backend/migrations/073_amazon_seed.sql ../../../backend/migrations/075_amazon_dispatch.sql ../../../backend/migrations/076_amazon_product_editor.sql ../../../backend/migrations/077_amazon_legal_soft.sql ../../../backend/migrations/078_amazon_decisions_chat.sql \
         ../../../backend/migrations/072_amazon_module.sql ../../../backend/migrations/075_amazon_dispatch.sql ../../../backend/migrations/076_amazon_product_editor.sql ../../../backend/migrations/077_amazon_legal_soft.sql ../../../backend/migrations/078_amazon_decisions_chat.sql; do   # 072 and 075 twice: must be re-runnable
  psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; psql -X -v ON_ERROR_STOP=1 -d $DB -f "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_amazon_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL SQL" | sed 's/^.*NOTICE:  //'
