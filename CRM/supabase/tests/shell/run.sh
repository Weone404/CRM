#!/usr/bin/env bash
# CRM shell checks: stub server -> Vite -> headless Chromium. Needs PLAYWRIGHT_DIR (node_modules with playwright); CHROME optional.
set -euo pipefail
cd "$(dirname "$0")"; ROOT=../../..
fuser -k 54398/tcp 5198/tcp >/dev/null 2>&1 || true
node stub.mjs > /tmp/shell_stub.log 2>&1 < /dev/null &
(cd $ROOT/frontend && npx vite --config ../supabase/tests/shell/vite.config.mjs > /tmp/shell_vite.log 2>&1 &)
for i in $(seq 1 40); do curl -s localhost:5198/ >/dev/null && curl -s localhost:54398/__mode >/dev/null && break; sleep 1; done
set +e; node shell_checks.mjs; c1=$?; node app_checks.mjs; c2=$?; code=$(( c1 || c2 ))
fuser -k 54398/tcp 5198/tcp >/dev/null 2>&1 || true
exit $code
