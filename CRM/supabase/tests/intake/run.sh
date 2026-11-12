#!/usr/bin/env bash
# ADS Phase 1 tests on a throwaway local Postgres. Usage: PGHOST=localhost PGUSER=postgres PGPASSWORD=... ./run.sh
# Order: live core -> fingerprint non-ADS objects -> 089 -> 089 again (re-runnable) -> fingerprint must be identical
#        -> tests -> down -> fingerprint identical again -> re-apply -> parallel submissions.
set -euo pipefail
cd "$(dirname "$0")"
DB=intake_test_$$
psql -q -c "CREATE DATABASE $DB" >/dev/null
trap 'psql -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null' EXIT
M=../../../backend/migrations
ap() { psql -q -X -v ON_ERROR_STOP=1 -d $DB -f "$1" >/dev/null 2>/tmp/ap_err_$$ || { echo "FAILED applying $1"; grep -m5 -E "ERROR|LINE" /tmp/ap_err_$$; exit 1; }; echo "applied $(basename $1)"; }
# Fingerprint of everything that is NOT ADS: definitions + grants of non-ads functions, columns/constraints/triggers
# of non-ads tables. Must not change when 089 is applied or rolled back.
fp() { psql -X -q -t -A -d $DB -c "SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
  SELECT p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, '') x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'crm_private') AND p.proname NOT LIKE '%ads%'
  UNION ALL SELECT c.relname || ':' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname NOT LIKE 'ads%' AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL SELECT conrelid::regclass::text || ':' || pg_get_constraintdef(oid) FROM pg_constraint
   WHERE conrelid::regclass::text NOT LIKE '%ads%' AND connamespace = 'public'::regnamespace
  UNION ALL SELECT 'refby:' || conrelid::regclass::text || '->' || confrelid::regclass::text FROM pg_constraint
   WHERE contype = 'f' AND confrelid::regclass::text NOT LIKE '%ads%'
  UNION ALL SELECT 'trg:' || tgrelid::regclass::text || ':' || tgname FROM pg_trigger
   WHERE tgrelid::regclass::text NOT LIKE '%ads%') s"; }
ap 00_live_core.sql
F0=$(fp)
ap $M/089_ads_leads_phase1.sql; ap $M/089_ads_leads_phase1.sql
F1=$(fp)
psql -X -q -t -v ON_ERROR_STOP=1 -d $DB -f 10_phase1_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL PHASE1" | sed 's/^.*NOTICE:  //'
[ "$F0" = "$F1" ] && echo "PASS N01 nothing outside ADS changed by 089 (functions, grants, tables, constraints, triggers)" || echo "FAIL N01 non-ADS objects changed"
ap $M/089_ads_leads_phase1_down.sql
F2=$(fp)
[ "$F0" = "$F2" ] && echo "PASS R01 rollback leaves non-ADS objects exactly as before" || echo "FAIL R01"
psql -X -q -t -d $DB -c "SELECT CASE WHEN to_regclass('public.ads_lead') IS NULL AND to_regclass('public.ads_enquiry') IS NULL
  AND to_regprocedure('public.svc_ads_ingest_enquiry(jsonb,text)') IS NULL
  AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'ads_access' AND column_name = 'role')
  THEN 'PASS R02 rollback removes all Phase 1 objects' ELSE 'FAIL R02' END"
ap $M/089_ads_leads_phase1.sql
psql -X -q -t -d $DB -c "CREATE TABLE ra AS SELECT public.svc_ads_ingest_enquiry('{\"name\":\"Again\",\"phone\":\"9877700008\",\"gclid\":\"G\"}', 'pilot_training') AS v" >/dev/null
psql -X -q -t -d $DB -c "SELECT CASE WHEN (SELECT v->>'status' FROM ra) = 'created'
  AND EXISTS (SELECT 1 FROM public.ads_lead WHERE phone_e164 = '+919877700008') THEN 'PASS R03 re-apply after rollback works' ELSE 'FAIL R03' END"
# Concurrency: 8 parallel ad enquiries from one number (different submissions) -> exactly one Ads lead, 8 enquiries.
for i in 1 2 3 4 5 6 7 8; do
  psql -X -q -t -d $DB -c "SELECT public.svc_ads_ingest_enquiry('{\"name\":\"Race\",\"phone\":\"9888800008\",\"gclid\":\"G\",\"submission_id\":\"race$i\"}', 'pilot_training')" >/dev/null &
done; wait
psql -X -q -t -d $DB -c "SELECT CASE WHEN (SELECT count(*) FROM public.ads_lead WHERE phone_e164 = '+919888800008') = 1
  AND (SELECT enquiry_count FROM public.ads_lead WHERE phone_e164 = '+919888800008') = 8
  AND (SELECT count(*) FROM public.ads_enquiry WHERE phone_e164 = '+919888800008') = 8 THEN 'PASS R04 8 parallel submissions -> 1 lead, 8 enquiries' ELSE 'FAIL R04' END"
