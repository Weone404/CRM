#!/bin/bash
# Installs the ADS agents helper (Google Ads) on this Mac. Run on the Mac Mini, in Terminal, from the repo:
#   bash ~/Desktop/CRM/CRM/CRM/tools/ads-agents/install.sh
# Separate from the Amazon helper (~/.nitaniya-bridge): this one lives in ~/.ads-agents with its own token.
# Needs Node.js 18+ and Claude Code logged in with the Max account. Starts at login; keeps the Mac awake while it runs.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HOME/.ads-agents"
LABEL="in.weoneaviation.ads-agents"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

NODE="$(command -v node || true)"
[ -z "$NODE" ] && [ -x /opt/homebrew/bin/node ] && NODE=/opt/homebrew/bin/node
[ -z "$NODE" ] && [ -x /usr/local/bin/node ] && NODE=/usr/local/bin/node
if [ -z "$NODE" ]; then echo "Node.js is missing. Install the LTS version from https://nodejs.org, then run this again."; exit 1; fi
"$NODE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' || { echo "Node.js 18 or newer is needed."; exit 1; }

CLAUDE="$(command -v claude || true)"
[ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE="$HOME/.local/bin/claude"
[ -z "$CLAUDE" ] && [ -x /opt/homebrew/bin/claude ] && CLAUDE=/opt/homebrew/bin/claude
[ -z "$CLAUDE" ] && { echo "Claude Code is missing. Install it:  curl -fsSL https://claude.ai/install.sh | bash   then run: claude  (log in)"; exit 1; }

echo "Checking that Claude Code is logged in (one short test message)..."
if ! OUT="$(cd /tmp && "$CLAUDE" -p --tools "" --no-session-persistence --max-turns 1 "Reply with the single word OK" 2>&1)"; then
  echo "Claude Code did not answer: $OUT"; echo "Run:  claude  and log in with your Max account, then run this again."; exit 1
fi

mkdir -p "$CONF"; chmod 700 "$CONF"
# The token is placed next to the repo by Claude (never shown in chat). Moved here and deleted from there.
DROP="$DIR/../../../../.ads-agents-token"
if [ -f "$DROP" ]; then ( umask 077; tr -d ' \n\r' < "$DROP" > "$CONF/token" ); rm -f "$DROP"
elif [ ! -s "$CONF/token" ]; then echo "No ADS agents token found. Ask Claude to make one, then run this again."; exit 1; fi
TOK="$(cat "$CONF/token")"; if [[ "$TOK" != adsag_* ]] || [ ${#TOK} -lt 40 ]; then echo "The token file looks wrong."; exit 1; fi
printf '%s' "$CLAUDE" > "$CONF/claude-path"
cp "$DIR/agents.mjs" "$DIR/prompts.mjs" "$DIR/uninstall.sh" "$CONF/"
"$NODE" --check "$CONF/agents.mjs" && "$NODE" --check "$CONF/prompts.mjs"

echo "Checking the connection to the CRM..."
if ! curl -fsS -X POST -H "Content-Type: application/json" -H "x-ads-agents-token: $TOK" -d '{"action":"ping"}' \
     https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-agents >/dev/null; then
  echo "The CRM did not accept the token. Ask Claude for a new one."; exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-i</string>
    <string>$NODE</string><string>$CONF/agents.mjs</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(dirname "$CLAUDE"):$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$CONF/agents.log</string>
  <key>StandardErrorPath</key><string>$CONF/agents.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3
echo "Done. The ADS agents are running on this Mac. Watch them in CRM > ADS > Autopilot."
echo "Log: $CONF/agents.log   Remove any time:  bash ~/.ads-agents/uninstall.sh"
