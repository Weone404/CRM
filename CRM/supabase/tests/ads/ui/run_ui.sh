#!/usr/bin/env bash
# Fresh database -> fake API -> Vite -> headless Chromium. Needs PGHOST/PGPORT/PGUSER, PG_MODULE_DIR (node_modules with pg)
# and PLAYWRIGHT_DIR (node_modules with playwright). CHROME (optional) = browser executable.
set -euo pipefail
cd "$(dirname "$0")"; ROOT=../../../..
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
psql -q -c "DROP DATABASE IF EXISTS ads_ui" -c "CREATE DATABASE ads_ui" >/dev/null 2>&1
for f in ../../amazon/00_supabase_stub.sql ../01_ads_stub.sql $ROOT/backend/migrations/076_ads_module.sql $ROOT/backend/migrations/078_ads_client_wizard.sql $ROOT/backend/migrations/089_ads_leads_phase1.sql $ROOT/backend/migrations/090_ads_leads_board.sql $ROOT/backend/migrations/091_ads_campaign_delivery.sql $ROOT/backend/migrations/092_ads_google_ops.sql $ROOT/backend/migrations/093_ads_autopilot.sql $ROOT/backend/migrations/094_ads_agents.sql $ROOT/backend/migrations/095_ads_hardening.sql $ROOT/backend/migrations/096_ads_supervisor.sql $ROOT/backend/migrations/097_ads_today.sql $ROOT/backend/migrations/098_ads_lead_attribution.sql $ROOT/backend/migrations/099_ads_team.sql $ROOT/backend/migrations/100_ads_meta_signals.sql $ROOT/backend/migrations/101_ads_meta_organic.sql $ROOT/backend/migrations/102_ads_meta_verification.sql $ROOT/backend/migrations/103_ads_meta_insights.sql $ROOT/backend/migrations/104_ads_meta_strategy.sql $ROOT/backend/migrations/105_ads_meta_reports.sql $ROOT/backend/migrations/106_ads_meta_quality.sql $ROOT/backend/migrations/107_ads_meta_funnel.sql $ROOT/backend/migrations/108_ads_site_signals.sql $ROOT/backend/migrations/109_ads_meta_funnel_plan.sql $ROOT/backend/migrations/110_ads_meta_actions.sql seed.sql seed_meta_insights.sql seed_meta_strategy.sql seed_meta_quality.sql seed_site_signals.sql; do
  psql -q -X -v ON_ERROR_STOP=1 -d ads_ui -f "$f" >/dev/null
done
PGDATABASE=ads_ui node fake_api.mjs > /tmp/ads_fake_api.log 2>&1 < /dev/null &
(cd $ROOT/frontend && npx vite --config ../supabase/tests/ads/ui/vite.config.mjs > /tmp/ads_vite.log 2>&1 &)
for i in $(seq 1 40); do curl -s localhost:5199/ >/dev/null && curl -s localhost:54399/__calls >/dev/null && break; sleep 1; done
set +e; node ${UI_SCRIPT:-ui_checks.mjs}; code=$?
fuser -k 54399/tcp 5199/tcp >/dev/null 2>&1 || true
exit $code
