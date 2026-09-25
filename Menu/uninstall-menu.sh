#!/bin/bash
# uninstall-menu.sh — remove TurboMenu app + agent (helper daemon untouched).
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist
rm -rf /Applications/TurboMenu.app
echo "menu removed"
