#!/bin/bash
# Installs the Nitaniya Live Claude helper on this Mac (run on the Mac Mini, in Terminal):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Weone404/CRM/main/CRM/tools/claude-bridge/install.sh)
# (or, from a clone of the repo:  bash CRM/tools/claude-bridge/install.sh)
# Needs: Node.js 18+ and Claude Code logged in with your Max account. Starts at login and keeps the Mac awake while running.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
REF="${NITANIYA_REF:-main}"
RAW="https://raw.githubusercontent.com/Weone404/CRM/$REF/CRM/tools/claude-bridge"
CONF="$HOME/.nitaniya-bridge"
LABEL="in.nitaniya.claude-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

NODE="$(command -v node || true)"
[ -z "$NODE" ] && [ -x /opt/homebrew/bin/node ] && NODE=/opt/homebrew/bin/node
[ -z "$NODE" ] && [ -x /usr/local/bin/node ] && NODE=/usr/local/bin/node
if [ -z "$NODE" ]; then echo "Node.js is missing. Install the LTS version from https://nodejs.org, then run this again."; exit 1; fi
if ! "$NODE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'; then echo "Node.js 18 or newer is needed."; exit 1; fi

CLAUDE="$(command -v claude || true)"
[ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE="$HOME/.local/bin/claude"
[ -z "$CLAUDE" ] && [ -x /opt/homebrew/bin/claude ] && CLAUDE=/opt/homebrew/bin/claude
if [ -z "$CLAUDE" ]; then
  echo "Claude Code is missing. Install it:  curl -fsSL https://claude.ai/install.sh | bash"
  echo "Then run:  claude   (log in with your Max account), and run this installer again."; exit 1
fi

echo "Checking that Claude Code is logged in (one short test message)..."
if ! OUT="$(cd /tmp && "$CLAUDE" -p --tools "" --no-session-persistence --max-turns 1 "Reply with the single word OK" 2>&1)"; then
  echo "Claude Code did not answer: $OUT"; echo "Open Terminal, run: claude  and log in with your Max account. Then run this again."; exit 1
fi

mkdir -p "$CONF"; chmod 700 "$CONF"
printf "Paste the Mac connection code from CRM > Amazon > More > Settings: "
read -r -s TOKEN < /dev/tty; echo
if [[ "$TOKEN" != nitb_* ]] || [ ${#TOKEN} -lt 60 ]; then echo "That is not a connection code. Copy it again from Settings."; exit 1; fi
( umask 077; printf '%s' "$TOKEN" > "$CONF/token" )
printf '%s' "$CLAUDE" > "$CONF/claude-path"
if [ -f "$DIR/bridge.mjs" ]; then cp "$DIR/bridge.mjs" "$CONF/bridge.mjs"
else curl -fsSL "$RAW/bridge.mjs" -o "$CONF/bridge.mjs"; curl -fsSL "$RAW/uninstall.sh" -o "$CONF/uninstall.sh"; fi
[ -f "$DIR/uninstall.sh" ] && cp "$DIR/uninstall.sh" "$CONF/uninstall.sh"
"$NODE" --check "$CONF/bridge.mjs" || { echo "The helper file did not download correctly. Try again."; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-i</string>
    <string>$NODE</string><string>$CONF/bridge.mjs</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(dirname "$CLAUDE"):$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$CONF/bridge.log</string>
  <key>StandardErrorPath</key><string>$CONF/bridge.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3
echo "Done. Live Claude is running on this Mac. In the CRM, the Claude chat should now say: Online."
echo "Log: $CONF/bridge.log   Remove it any time:  bash ~/.nitaniya-bridge/uninstall.sh"
