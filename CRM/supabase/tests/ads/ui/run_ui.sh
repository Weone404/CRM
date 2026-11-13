#!/usr/bin/env bash
# Fresh database -> fake API -> Vite -> headless Chromium. Needs PGHOST/PGPORT/PGUSER, PG_MODULE_DIR (node_modules with pg)
# and PLAYWRIGHT_DIR (node_modules with playwright). CHROME (optional) = browser executable.
set -euo pipefail
cd "$(dirname "$0")"; ROOT=../../../..
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
psql -q -c "DROP DATABASE IF EXISTS ads_ui" -c "CREATE DATABASE ads_ui" >/dev/null 2>&1
for f in ../../amazon/00_supabase_stub.sql ../01_ads_stub.sql $ROOT/backend/migrations/076_ads_module.sql $ROOT/backend/migrations/078_ads_client_wizard.sql $ROOT/backend/migrations/091_ads_campaign_delivery.sql $ROOT/backend/migrations/092_ads_google_ops.sql $ROOT/backend/migrations/093_ads_autopilot.sql $ROOT/backend/migrations/094_ads_agents.sql $ROOT/backend/migrations/095_ads_hardening.sql $ROOT/backend/migrations/096_ads_supervisor.sql seed.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d ads_ui -f "$f" >/dev/null
done
PGDATABASE=ads_ui node fake_api.mjs > /tmp/ads_fake_api.log 2>&1 < /dev/null &
(cd $ROOT/frontend && npx vite --config ../supabase/tests/ads/ui/vite.config.mjs > /tmp/ads_vite.log 2>&1 &)
for i in $(seq 1 40); do curl -s localhost:5199/ >/dev/null && curl -s localhost:54399/__calls >/dev/null && break; sleep 1; done
set +e; node ${UI_SCRIPT:-ui_checks.mjs}; code=$?
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
exit $code
