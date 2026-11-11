#!/bin/bash
# Stops and removes the Nitaniya Live Claude helper from this Mac. (Also revoke the code in CRM Settings.)
LABEL="in.nitaniya.claude-bridge"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.nitaniya-bridge"
echo "Live Claude helper removed from this Mac."
