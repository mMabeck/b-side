#!/bin/bash
# Builds BSide in release mode and assembles a real "B-Side.app" under dist/.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="B-Side"
BUNDLE_ID="dev.mabeck.bside"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICNS_PATH="assets/icon/AppIcon.icns"

echo "Building BSide (release)..."
swift build -c release --product BSide

BIN_PATH=".build/release/BSide"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

if [ ! -f "$ICNS_PATH" ]; then
    echo "Icon missing, regenerating..."
    assets/icon/make-icns.sh
fi

echo "Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/BSide"
cp "$ICNS_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>BSide</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Seal the bundle with an ad-hoc signature. The linker's own signature covers
# only the binary, under the identifier "BSide", with Info.plist unbound, so
# usernotificationsd rejects every notification request ("addRequest not
# allowed: dev.mabeck.bside"). Signing the assembled .app binds Info.plist and
# makes the code identity match the bundle identifier.
echo "Signing $APP_DIR (ad-hoc)..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "Built $APP_DIR"
