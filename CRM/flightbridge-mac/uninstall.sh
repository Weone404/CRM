#!/bin/bash
# Stops the FlightBridge engine on this Mac and removes the background job (keeps ~/FlightBridgeEngine and its .env).
PLIST="$HOME/Library/LaunchAgents/in.weoneaviation.flightbridge-engine.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
rm -f "$PLIST"
echo "FlightBridge engine stopped and removed from login items."
