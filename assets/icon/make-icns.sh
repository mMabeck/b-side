#!/bin/sh
# Render the icon artwork and pack it into a macOS .icns.
#
# The full-bleed square art is masked to Apple's rounded-rect and inset into the
# standard 824/1024 content box, so it sits correctly next to system icons.
#
# usage: assets/icon/make-icns.sh [--no-arm]
set -eu
here=$(cd "$(dirname "$0")" && pwd)

python3 "$here/icon.py" "$@" --out "$here/icon.png"
python3 "$here/mask.py" "$here/icon.png" "$here/icon-masked.png"

set -- 16 32 64 128 256 512 1024
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for px in "$@"; do
  sips -z "$px" "$px" "$here/icon-masked.png" --out "$iconset/tmp-$px.png" >/dev/null
done
cp "$iconset/tmp-16.png"   "$iconset/icon_16x16.png"
cp "$iconset/tmp-32.png"   "$iconset/icon_16x16@2x.png"
cp "$iconset/tmp-32.png"   "$iconset/icon_32x32.png"
cp "$iconset/tmp-64.png"   "$iconset/icon_32x32@2x.png"
cp "$iconset/tmp-128.png"  "$iconset/icon_128x128.png"
cp "$iconset/tmp-256.png"  "$iconset/icon_128x128@2x.png"
cp "$iconset/tmp-256.png"  "$iconset/icon_256x256.png"
cp "$iconset/tmp-512.png"  "$iconset/icon_256x256@2x.png"
cp "$iconset/tmp-512.png"  "$iconset/icon_512x512.png"
cp "$iconset/tmp-1024.png" "$iconset/icon_512x512@2x.png"
rm -f "$iconset"/tmp-*.png

iconutil -c icns "$iconset" -o "$here/AppIcon.icns"
echo "$here/AppIcon.icns"
