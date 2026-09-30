#!/bin/bash
# Packs an app bundle into a compressed drag-to-Applications disk image.
set -euo pipefail

APP_DIR="${1:?usage: $0 path/to/App.app output.dmg}"
DMG_PATH="${2:?usage: $0 path/to/App.app output.dmg}"
VOLUME_NAME="$(basename "$APP_DIR" .app)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_DIR" "$STAGING/$(basename "$APP_DIR")"
ln -s /Applications "$STAGING/Applications"

hdiutil create -quiet -ov -fs APFS -format ULFO \
    -volname "$VOLUME_NAME" -srcfolder "$STAGING" "$DMG_PATH"
hdiutil verify -quiet "$DMG_PATH"
echo "Built $DMG_PATH"
