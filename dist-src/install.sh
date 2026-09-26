#!/bin/bash
# install.sh — end-user installer (from the release zip). Intel Macs only.
# Usage: ./install.sh [--enable|--disable]   (default: --disable)
# Asks for sudo password once for the system daemon; menu part needs no auth.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:---disable}"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "This tool needs an Intel Mac (the DisableTurboBoost kext is Intel-only)."
  echo "Apple Silicon Macs manage thermals differently; this package cannot help."
  exit 1
fi
for f in files/tbhelper files/LaunchDaemon.plist; do
  [ -f "$f" ] || { echo "missing $f — re-download the release zip"; exit 1; }
done

echo "[1/4] installing privileged helper (sudo, one password prompt)"
sudo bash -c '
set -e
SUPPORT_DIR="/Library/Application Support/TurboBoostSwitcher"
HELPER_BIN="/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper"
LAUNCH_PLIST="/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist"
SRC_DIR="'"$PWD"'/files"
mkdir -p "$SUPPORT_DIR"
if [ "'"$MODE"'" = "--disable" ]; then
  printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" "<plist version=\"1.0\"><dict><key>disabled</key><true/></dict></plist>" > "$SUPPORT_DIR/wanted-state.plist"
else
  printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" "<plist version=\"1.0\"><dict><key>disabled</key><false/></dict></plist>" > "$SUPPORT_DIR/wanted-state.plist"
fi
chown root:wheel "$SUPPORT_DIR" "$SUPPORT_DIR/wanted-state.plist"
chmod 755 "$SUPPORT_DIR"; chmod 644 "$SUPPORT_DIR/wanted-state.plist"
mkdir -p /Library/PrivilegedHelperTools
cp -f "$SRC_DIR/tbhelper" "$HELPER_BIN"
chown root:wheel "$HELPER_BIN"; chmod 544 "$HELPER_BIN"
cp -f "$SRC_DIR/LaunchDaemon.plist" "$LAUNCH_PLIST"
chown root:wheel "$LAUNCH_PLIST"; chmod 644 "$LAUNCH_PLIST"
launchctl bootout system "$LAUNCH_PLIST" 2>/dev/null || true
launchctl bootstrap system "$LAUNCH_PLIST"
launchctl enable "system/com.local.TurboBoostSwitcher.helper" 2>/dev/null || true
'

echo "[2/4] applying desired state"
sleep 3
if [ "$MODE" = "--disable" ]; then
  kextstat 2>/dev/null | grep -q com.rugarciap.DisableTurboBoost && echo "turbo OFF" || { /usr/bin/kmutil load -b com.rugarciap.DisableTurboBoost && echo "turbo OFF"; }
else
  /sbin/kextunload -b com.rugarciap.DisableTurboBoost 2>/dev/null || true
  echo "turbo ON"
fi

echo "[3/4] installing Mac Turbo Disabler + auto-start (no auth needed)"
# Retire pre-rename TurboMenu install if present.
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.TurboBoostMenu.plist
rm -rf /Applications/TurboMenu.app
if [ -d "MacTurboDisabler.app" ]; then
  rm -rf /Applications/MacTurboDisabler.app
  cp -R MacTurboDisabler.app /Applications/
  mkdir -p ~/Library/LaunchAgents
  cp files/MenuAgent.plist ~/Library/LaunchAgents/com.local.MacTurboDisabler.plist
  launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.local.MacTurboDisabler.plist 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.local.MacTurboDisabler.plist
  launchctl enable "gui/$(id -u)/com.local.MacTurboDisabler" 2>/dev/null || true
  echo "menu installed (look for TB ON/OFF top-right)"
else
  echo "MacTurboDisabler.app not in package, skipping menu"
fi

echo "[4/4] done. Sleep/wake your Mac to confirm: no password prompt, ever."
echo "Uninstall: ./uninstall.sh"
