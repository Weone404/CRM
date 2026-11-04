#!/bin/bash
# Installs the FlightBridge engine on this Mac as a background job: starts at login, restarts if it stops,
# keeps the Mac from idle-sleeping while it runs. Run it from Terminal:  bash CRM/flightbridge-mac/install.sh
# First run creates ~/FlightBridgeEngine/.env for you to fill in; run it again afterwards to start the engine.
# Undo: bash CRM/flightbridge-mac/uninstall.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_HOME="$HOME/FlightBridgeEngine"
LABEL="in.weoneaviation.flightbridge-engine"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PIN="$(grep -E '^flightbridge @' "$HERE/../backend/requirements.txt" || true)"
[ -n "$PIN" ] || { echo "Could not find the flightbridge line in backend/requirements.txt"; exit 1; }

PY=""
for c in python3.13 python3.12 python3.11 "$HOME/.pyenv/shims/python3" /opt/homebrew/bin/python3 python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
    PY="$(command -v "$c")"; break
  fi
done
[ -n "$PY" ] || { echo "Python 3.11 or newer is needed. Install it with:  brew install python@3.12   then run this again."; exit 1; }

mkdir -p "$ENGINE_HOME/logs" "$HOME/Library/LaunchAgents"
echo "Setting up the engine in $ENGINE_HOME (Python: $PY) ..."
[ -x "$ENGINE_HOME/venv/bin/python" ] || "$PY" -m venv "$ENGINE_HOME/venv"
"$ENGINE_HOME/venv/bin/python" -m pip install --quiet --upgrade pip
"$ENGINE_HOME/venv/bin/python" -m pip install --quiet --upgrade "$PIN"
cp "$HERE/runner.py" "$ENGINE_HOME/runner.py"

if [ ! -f "$ENGINE_HOME/.env" ]; then
  cp "$HERE/env.example" "$ENGINE_HOME/.env"
fi
chmod 600 "$ENGINE_HOME/.env"
if grep -q "PASTE_" "$ENGINE_HOME/.env"; then
  echo
  echo "Almost done: fill in DATABASE_URL and FB_SECRETS_KEY in $ENGINE_HOME/.env (opening it now),"
  echo "save it, then run this script again."
  open -e "$ENGINE_HOME/.env" 2>/dev/null || true
  exit 0
fi

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-i</string>
    <string>$ENGINE_HOME/venv/bin/python</string><string>$ENGINE_HOME/runner.py</string>
  </array>
  <key>WorkingDirectory</key><string>$ENGINE_HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$ENGINE_HOME/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ENGINE_HOME/logs/launchd.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Started. Checking the first minute of the log ..."
sleep 45
tail -n 15 "$ENGINE_HOME/logs/engine.log" 2>/dev/null || tail -n 15 "$ENGINE_HOME/logs/launchd.log"
echo
echo "FlightBridge engine is running on this Mac. Log: $ENGINE_HOME/logs/engine.log"
