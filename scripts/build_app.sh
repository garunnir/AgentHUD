#!/usr/bin/env bash
# Builds AgentHud.macOS into a double-clickable AgentHud.app bundle.
#
#   ./scripts/build_app.sh            # release build
#   CONFIG=debug ./scripts/build_app.sh
#
# Output: src/AgentHud.macOS/dist/AgentHud.app
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/src/AgentHud.macOS"
DIST="$PACKAGE/dist"
APP="$DIST/AgentHud.app"
BUNDLE_ID="com.garunnir.agenthud"
VERSION="0.1.0"

cd "$PACKAGE"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product AgentHud
PRODUCT_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCT_DIR/AgentHud" "$APP/Contents/MacOS/AgentHud"

# SwiftPM resource bundle (localization table) — Bundle.module looks it up in Contents/Resources.
if [ -d "$PRODUCT_DIR/AgentHud_AgentHud.bundle" ]; then
    cp -R "$PRODUCT_DIR/AgentHud_AgentHud.bundle" "$APP/Contents/Resources/"
else
    echo "!! resource bundle not found at $PRODUCT_DIR/AgentHud_AgentHud.bundle" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Agent HUD</string>
    <key>CFBundleDisplayName</key>
    <string>Agent HUD</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>AgentHud</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Accessory app: no Dock icon, lives as a HUD panel. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: keeps Gatekeeper quiet for locally built apps (no Apple account needed).
if command -v codesign >/dev/null 2>&1; then
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
fi

echo "==> Built: $APP"
echo "    Run with: open \"$APP\""