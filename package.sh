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
codesign -s - -f "$STAGE/TurboMenu.app" 2>/dev/null || true
cp "$CLONE_DIR/dist-src/install.sh" "$CLONE_DIR/dist-src/uninstall.sh" "$STAGE/"
cp "$CLONE_DIR/README.md" "$CLONE_DIR/NOTICE" "$CLONE_DIR/LICENSE" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

echo "[3/4] zipping"
ZIP="$CLONE_DIR/dist/TurboBoostSwitcherPro-${VER}-mac-intel.zip"
rm -f "$ZIP"
(cd "$CLONE_DIR/dist/stage" && zip -qr "$ZIP" TurboBoostSwitcherPro)
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo "[4/4] done: $ZIP"
ls -la "$ZIP"
