#!/bin/bash
# uninstall-menu.sh — remove Mac Turbo Disabler app + agent (helper daemon untouched).
# Also cleans the pre-rename TurboMenu install.
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.MacTurboDisabler.plist 2>/dev/null || true
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.MacTurboDisabler.plist
rm -f ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist
rm -rf /Applications/MacTurboDisabler.app
rm -rf /Applications/TurboMenu.app
echo "menu removed"
