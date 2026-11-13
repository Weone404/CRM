#!/bin/bash
# Stops and removes the ADS agents helper from this Mac (the Amazon helper is not touched).
LABEL="in.weoneaviation.ads-agents"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.ads-agents"
echo "ADS agents helper removed."
