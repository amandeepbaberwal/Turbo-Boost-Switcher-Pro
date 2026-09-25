#!/bin/bash
# uninstall.sh — fully revert install.sh.
set -euo pipefail
echo "Removing menu agent..."
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist
rm -rf /Applications/TurboMenu.app
echo "Removing privileged helper (sudo)..."
sudo bash -c '
LAUNCH_PLIST="/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist"
launchctl bootout system "$LAUNCH_PLIST" 2>/dev/null || true
rm -f "$LAUNCH_PLIST" /Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper
rm -rf "/Library/Application Support/TurboBoostSwitcher"
rm -f /var/log/tbhelper.log
'
echo "Reverted."
