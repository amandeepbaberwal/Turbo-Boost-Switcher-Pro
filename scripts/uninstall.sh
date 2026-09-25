#!/bin/bash
# uninstall.sh — fully revert install-dev.sh. Restores stock free-app behavior.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Re-run with sudo: sudo $0"; exit 1; fi
LAUNCH_PLIST="/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist"
echo "Unloading daemon (if present)..."
launchctl bootout system "$LAUNCH_PLIST" 2>/dev/null || true
rm -f "$LAUNCH_PLIST" /Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper
rm -rf "/Library/Application Support/TurboBoostSwitcher"
rm -f /var/log/tbhelper.log
echo "Reverted. Relaunch Turbo Boost Switcher.app normally if you still want the GUI."
