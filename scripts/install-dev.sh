#!/bin/bash
# install-dev.sh — test the helper WITHOUT SMJobBless signing.
# Asks for sudo password ONCE, then the helper owns kext loading forever.
# Reuses the upstream kext from the cloned repo. Fully reverted by uninstall.sh.
set -euo pipefail

SUPPORT_DIR="/Library/Application Support/TurboBoostSwitcher"
HELPER_BIN="/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper"
LAUNCH_PLIST="/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLONE_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run with sudo: sudo $0 [--enable|--disable]"
  exit 1
fi
MODE="${1:---disable}"  # default: permanently OFF, the requested behavior

if [ ! -x "$CLONE_DIR/build/tbhelper" ]; then
  echo "Build the helper first (see Helper/BUILD.md), expected at $CLONE_DIR/build/tbhelper"
  exit 1
fi

echo "[1/5] state dir + VoltageShift engine (preserve existing choices)"
mkdir -p "$SUPPORT_DIR"
rm -rf "$SUPPORT_DIR/DisableTurboBoost.64bits.kext"  # remove unloadable copy from earlier revision
if [ ! -f "$SUPPORT_DIR/wanted-state.plist" ]; then
  if [ "$MODE" = "--disable" ]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict><key>disabled</key><true/></dict></plist>' > "$SUPPORT_DIR/wanted-state.plist"
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict><key>disabled</key><false/></dict></plist>' > "$SUPPORT_DIR/wanted-state.plist"
  fi
fi
chown root:wheel "$SUPPORT_DIR" "$SUPPORT_DIR/wanted-state.plist"; chmod 755 "$SUPPORT_DIR"; chmod 644 "$SUPPORT_DIR/wanted-state.plist"
cp -f "$CLONE_DIR/VShift/prebuilt/voltageshift" "$SUPPORT_DIR/voltageshift"
chown root:wheel "$SUPPORT_DIR/voltageshift"; chmod 755 "$SUPPORT_DIR/voltageshift"
rm -rf /Library/Extensions/VoltageShift.kext
cp -R "$CLONE_DIR/VShift/prebuilt/VoltageShift.kext" /Library/Extensions/
chown -R root:wheel /Library/Extensions/VoltageShift.kext; chmod -R 755 /Library/Extensions/VoltageShift.kext

echo "[2/5] installing helper binary"
mkdir -p /Library/PrivilegedHelperTools
cp -f "$CLONE_DIR/build/tbhelper" "$HELPER_BIN"
chown root:wheel "$HELPER_BIN"; chmod 544 "$HELPER_BIN"

echo "[3/5] installing LaunchDaemon"
cp -f "$CLONE_DIR/Helper/LaunchDaemon.plist" "$LAUNCH_PLIST"
chown root:wheel "$LAUNCH_PLIST"; chmod 644 "$LAUNCH_PLIST"

echo "[4/5] (re)starting daemon"
launchctl bootout system "$LAUNCH_PLIST" 2>/dev/null || true
launchctl bootstrap system "$LAUNCH_PLIST"
launchctl enable "system/com.local.TurboBoostSwitcher.helper" 2>/dev/null || true

echo "[5/5] applying desired state now"
sleep 3
if [ "$MODE" = "--disable" ]; then
  kextstat 2>/dev/null | grep -q com.rugarciap.DisableTurboBoost && echo "kext loaded (turbo OFF)" || { echo "boot-restore pending, forcing load by bundle ID:"; /usr/bin/kmutil load -b com.rugarciap.DisableTurboBoost && echo OK; }
else
  kextunload -b com.rugarciap.DisableTurboBoost 2>/dev/null || true
  echo "kext unloaded (turbo ON)"
fi

echo "Done. Test: sleep the Mac, wake it, confirm NO password prompt."
echo "Logs: tail -f /var/log/tbhelper.log"
echo "IMPORTANT: quit Turbo Boost Switcher.app (or apply AppDelegate-patch) or its"
echo "own wake handler will STILL prompt — the GUI must stop touching the kext."
