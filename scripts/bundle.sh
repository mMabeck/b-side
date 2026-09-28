#!/bin/bash
# Builds BSide in release mode and assembles a real "B-Side.app" under dist/.
# --install also copies it to /Applications (Spotlight, Raycast, Launchpad).
set -euo pipefail

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "usage: $0 [--install]" >&2; exit 2 ;;
    esac
done

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
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- UTType(exportedAs:) in SidebarView; undeclared, project drag-reorder silently fails. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.mabeck.bside.project-id</string>
            <key>UTTypeDescription</key>
            <string>B-Side Project</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Seal the bundle with an ad-hoc signature. The linker's own signature covers
# only the binary, under the identifier "BSide", with Info.plist unbound, so
# usernotificationsd rejects every notification request ("addRequest not
# allowed: dev.mabeck.bside"). Signing the assembled .app binds Info.plist and
# makes the code identity match the bundle identifier.
# The stable local identity from make-signing-identity.sh keeps privacy (TCC)
# grants across rebuilds; an ad-hoc signature changes with every build.
SIGN_KEYCHAIN="$HOME/Library/Keychains/bside-signing.keychain-db"
SIGN_IDENTITY="-"
if [ -f "$SIGN_KEYCHAIN" ]; then
    security unlock-keychain -p "bside-local" "$SIGN_KEYCHAIN"
    SIGN_IDENTITY="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" \
        | awk '/"B-Side Local Signing"/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_IDENTITY="-"
    echo "note: ad-hoc signing; run scripts/make-signing-identity.sh to stop repeated privacy prompts"
fi
echo "Signing $APP_DIR..."
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "Built $APP_DIR"

if [ "$INSTALL" = 1 ]; then
    INSTALL_DIR="/Applications/$APP_NAME.app"
    STAGED="/Applications/.$APP_NAME.app.new"
    OLD="/Applications/.$APP_NAME.app.old"
    rm -rf "$STAGED" "$OLD"
    ditto "$APP_DIR" "$STAGED"
    # Swap by rename so a running copy keeps its open inodes instead of
    # having files rewritten underneath it.
    [ -e "$INSTALL_DIR" ] && mv "$INSTALL_DIR" "$OLD"
    mv "$STAGED" "$INSTALL_DIR"
    rm -rf "$OLD"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR"
    echo "Installed $INSTALL_DIR"
fi
