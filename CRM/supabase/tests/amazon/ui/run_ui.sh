#!/usr/bin/env bash
# Fresh database -> fake API -> Vite -> headless Chrome. Needs PGHOST/PGPORT/PGUSER, PG_MODULE_DIR (node_modules with pg),
# PLAYWRIGHT_DIR (node_modules with playwright) and Chrome at /usr/bin/google-chrome.
set -euo pipefail
cd "$(dirname "$0")"; ROOT=../../../..
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
psql -q -c "DROP DATABASE IF EXISTS amz_ui" -c "CREATE DATABASE amz_ui" >/dev/null 2>&1
for f in ../00_supabase_stub.sql $ROOT/backend/migrations/072_amazon_module.sql $ROOT/backend/migrations/073_amazon_seed.sql $ROOT/backend/migrations/075_amazon_dispatch.sql $ROOT/backend/migrations/076_amazon_product_editor.sql $ROOT/backend/migrations/077_amazon_legal_soft.sql $ROOT/backend/migrations/078_amazon_decisions_chat.sql $ROOT/backend/migrations/080_amazon_fixall_alerts.sql $ROOT/backend/migrations/081_amazon_personal.sql $ROOT/backend/migrations/082_amazon_notify.sql $ROOT/backend/migrations/083_amazon_market_keywords.sql $ROOT/backend/migrations/084_amazon_keyword_quality.sql $ROOT/backend/migrations/085_amazon_keyword_smart.sql $ROOT/backend/migrations/086_amazon_studio.sql $ROOT/backend/migrations/087_amazon_studio_design.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d amz_ui -f "$f" >/dev/null 2>&1
done
psql -q -d amz_ui -c "INSERT INTO public.employee (id, name, department, auth_user_id) VALUES
  ('00000000-0000-0000-0000-00000000000a','Nikhil','Admin','10000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b','Sales Rep','Sales','10000000-0000-0000-0000-00000000000b');" >/dev/null
PGDATABASE=amz_ui node fake_api.mjs > /tmp/amz_fake_api.log 2>&1 < /dev/null &
(cd $ROOT/frontend && npx vite --config ../supabase/tests/amazon/ui/vite.config.mjs > /tmp/amz_vite.log 2>&1 &)
for i in $(seq 1 30); do curl -s localhost:5199/ >/dev/null && curl -s localhost:54399/__calls >/dev/null && break; sleep 1; done
set +e; node ui_checks.mjs; code=$?
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
exit $code
