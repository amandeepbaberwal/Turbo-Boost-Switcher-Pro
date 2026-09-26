#!/bin/bash
# build-install-menu.sh — compile Mac Turbo Disabler, install .app + auto-start agent.
# No sudo needed (user-level LaunchAgent). Run: ./Menu/build-install-menu.sh
set -euo pipefail
CLONE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=/Applications/MacTurboDisabler.app
AGENT=~/Library/LaunchAgents/com.local.MacTurboDisabler.plist
OLD_APP=/Applications/TurboMenu.app
OLD_AGENT=~/Library/LaunchAgents/com.local.TurboBoostMenu.plist

echo "[1/4] compiling helper + menu"
mkdir -p "$CLONE_DIR/build"
xcrun clang -O2 -fobjc-arc -Wno-nullability-completeness -I "$CLONE_DIR/Shared" \
  -framework Foundation -framework IOKit \
  "$CLONE_DIR/Helper/main.m" "$CLONE_DIR/Helper/TurboBoostHelper.m" \
  -o "$CLONE_DIR/build/tbhelper"
xcrun swiftc -O -framework Cocoa "$CLONE_DIR/Menu/"*.swift -o "$CLONE_DIR/build/MacTurboDisabler"

echo "[1b/4] migrating old TurboMenu install (if any)"
launchctl bootout "gui/$(id -u)" "$OLD_AGENT" 2>/dev/null || true
rm -f "$OLD_AGENT"
killall TurboMenu 2>/dev/null || true
rm -rf "$OLD_APP"

echo "[2/4] assembling .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$CLONE_DIR/build/MacTurboDisabler" "$APP/Contents/MacOS/"
cp "$CLONE_DIR/Menu/Info.plist" "$APP/Contents/"
cp "$CLONE_DIR/build/tbhelper" "$APP/Contents/Resources/"
cp "$CLONE_DIR/Helper/LaunchDaemon.plist" "$APP/Contents/Resources/"
cp "$CLONE_DIR/VShift/prebuilt/voltageshift" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/VoltageShift.kext"
cp -R "$CLONE_DIR/VShift/prebuilt/VoltageShift.kext" "$APP/Contents/Resources/"
codesign -s - -f "$APP" 2>/dev/null || true

echo "[3/4] installing LaunchAgent (auto-start at login)"
mkdir -p ~/Library/LaunchAgents
cp "$CLONE_DIR/Menu/LaunchAgent.plist" "$AGENT"
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
sleep 1
killall MacTurboDisabler 2>/dev/null || true  # clear manually-launched strays (agent KeepAlive would resurrect)
sleep 1
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl enable "gui/$(id -u)/com.local.MacTurboDisabler" 2>/dev/null || true

echo "[4/4] verifying"
sleep 3
COUNT=$(pgrep -f "MacTurboDisabler.app" | wc -l | tr -d ' ')
if [ "$COUNT" = "1" ]; then echo "menu running once (look for TB ON/OFF top-right)";
elif [ "$COUNT" = "0" ]; then echo "not running; launching once:"; open "$APP";
else echo "WARNING: $COUNT copies running, cleaning:"; launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true; killall MacTurboDisabler 2>/dev/null || true; sleep 1; launchctl bootstrap "gui/$(id -u)" "$AGENT"; fi
