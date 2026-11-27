#!/usr/bin/env bash
# Fresh database -> fake API -> Vite -> headless Chromium (phone, tablet, laptop). Needs PGHOST/PGPORT/PGUSER,
# PG_MODULE_DIR (node_modules with pg) and PLAYWRIGHT_DIR (node_modules with playwright). Screenshots: /tmp/wa_ui_*.png
set -euo pipefail
cd "$(dirname "$0")"; ROOT=../../../..
fuser -k 54398/tcp 5198/tcp >/dev/null 2>&1 || true
psql -q -c "DROP DATABASE IF EXISTS wa_ui" -c "CREATE DATABASE wa_ui" >/dev/null 2>&1
for f in ../../amazon/00_supabase_stub.sql ../01_wa_stub.sql $ROOT/backend/migrations/150_whatsapp.sql seed.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d wa_ui -f "$f" >/dev/null
done
export RIYA_LEAD=$(psql -tA -d wa_ui -c "SELECT id FROM public.lead WHERE dedup_key = '+919811000001'")
PGDATABASE=wa_ui node --experimental-strip-types fake_api.mjs > /tmp/wa_fake_api.log 2>&1 < /dev/null &
(cd $ROOT/frontend && npx vite --config ../supabase/tests/wa/ui/vite.config.mjs > /tmp/wa_vite.log 2>&1 &)
for i in $(seq 1 60); do curl -s localhost:5198/ >/dev/null && curl -s -X OPTIONS localhost:54398/ >/dev/null && break; sleep 1; done
set +e; node wa_ui.mjs; code=$?
fuser -k 54398/tcp 5198/tcp >/dev/null 2>&1 || true
exit $code
