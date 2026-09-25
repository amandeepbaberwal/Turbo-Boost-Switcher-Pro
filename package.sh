#!/bin/bash
# package.sh — rebuild everything from source and assemble the release zip.
# Usage: ./package.sh   → dist/TurboBoostSwitcherPro-1.0-mac-intel.zip + .sha256
set -euo pipefail
CLONE_DIR="$(cd "$(dirname "$0")" && pwd)"
VER="1.0"
STAGE="$CLONE_DIR/dist/stage/TurboBoostSwitcherPro"
mkdir -p "$CLONE_DIR/build" "$CLONE_DIR/dist"

echo "[1/4] rebuilding helper (Intel)"
xcrun clang -O2 -fobjc-arc -Wno-nullability-completeness -I "$CLONE_DIR/Shared" \
  -framework Foundation -framework IOKit \
  "$CLONE_DIR/Helper/main.m" "$CLONE_DIR/Helper/TurboBoostHelper.m" \
  -o "$CLONE_DIR/build/tbhelper"

echo "[2/4] rebuilding menu + .app"
xcrun swiftc -O -framework Cocoa "$CLONE_DIR/Menu/TurboMenu.swift" -o "$CLONE_DIR/build/TurboMenu"
rm -rf "$STAGE"
mkdir -p "$STAGE/files" "$STAGE/TurboMenu.app/Contents/MacOS" "$STAGE/TurboMenu.app/Contents/Resources"
cp "$CLONE_DIR/build/tbhelper" "$STAGE/files/"
cp "$CLONE_DIR/Helper/LaunchDaemon.plist" "$STAGE/files/"
cp "$CLONE_DIR/Menu/LaunchAgent.plist" "$STAGE/files/MenuAgent.plist"
cp "$CLONE_DIR/build/TurboMenu" "$STAGE/TurboMenu.app/Contents/MacOS/"
cp "$CLONE_DIR/Menu/Info.plist" "$STAGE/TurboMenu.app/Contents/"
cp "$CLONE_DIR/build/tbhelper" "$STAGE/TurboMenu.app/Contents/Resources/"
cp "$CLONE_DIR/Helper/LaunchDaemon.plist" "$STAGE/TurboMenu.app/Contents/Resources/"
codesign -s - -f "$STAGE/TurboMenu.app" 2>/dev/null || true
cp "$CLONE_DIR/dist-src/install.sh" "$CLONE_DIR/dist-src/uninstall.sh" "$STAGE/"
cp "$CLONE_DIR/README.md" "$CLONE_DIR/NOTICE" "$CLONE_DIR/LICENSE" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

echo "[3/4] zipping"
ZIP="$CLONE_DIR/dist/TurboBoostSwitcherPro-${VER}-mac-intel.zip"
rm -f "$ZIP"
(cd "$CLONE_DIR/dist/stage" && zip -qr "$ZIP" TurboBoostSwitcherPro)
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "[4/5] building .pkg installer (double-clickable)"
chmod +x "$CLONE_DIR/pkg/scripts/preinstall" "$CLONE_DIR/pkg/scripts/postinstall"
PKGROOT="$CLONE_DIR/dist/stage/pkgroot"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Library/PrivilegedHelperTools" \
         "$PKGROOT/Library/LaunchDaemons" \
         "$PKGROOT/Library/LaunchAgents" \
         "$PKGROOT/Applications/TurboMenu.app/Contents/MacOS" \
         "$PKGROOT/Applications/TurboMenu.app/Contents/Resources"
cp "$CLONE_DIR/build/tbhelper" "$PKGROOT/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper"
cp "$CLONE_DIR/Helper/LaunchDaemon.plist" "$PKGROOT/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist"
cp "$CLONE_DIR/Menu/LaunchAgent.plist" "$PKGROOT/Library/LaunchAgents/com.local.TurboBoostMenu.plist"
cp "$CLONE_DIR/build/TurboMenu" "$PKGROOT/Applications/TurboMenu.app/Contents/MacOS/"
cp "$CLONE_DIR/Menu/Info.plist" "$PKGROOT/Applications/TurboMenu.app/Contents/"
cp "$CLONE_DIR/build/tbhelper" "$PKGROOT/Applications/TurboMenu.app/Contents/Resources/"
cp "$CLONE_DIR/Helper/LaunchDaemon.plist" "$PKGROOT/Applications/TurboMenu.app/Contents/Resources/"
codesign -s - -f "$PKGROOT/Applications/TurboMenu.app" 2>/dev/null || true
chmod 544 "$PKGROOT/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper"
chmod 644 "$PKGROOT/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist" \
          "$PKGROOT/Library/LaunchAgents/com.local.TurboBoostMenu.plist"
PKG="$CLONE_DIR/dist/TurboBoostSwitcherPro-${VER}-mac-intel.pkg"
rm -f "$PKG"
pkgbuild --root "$PKGROOT" \
  --scripts "$CLONE_DIR/pkg/scripts" \
  --identifier com.local.turboboostswitcher.pro \
  --version "$VER" \
  --install-location / \
  "$PKG"
shasum -a 256 "$PKG" | tee "$PKG.sha256"

echo "[5/5] done:"
ls -la "$ZIP" "$PKG"
