#!/bin/bash
# Builds this checkout as "B-Side Test" (own bundle id, defaults and data dir),
# seeds sample projects on first run, and opens it next to the real B-Side,
# which is never touched. --reset wipes the test copy's data and reseeds.
set -euo pipefail

RESET=0
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        *) echo "usage: $0 [--reset]" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

export BSIDE_APP_NAME="B-Side Test"
export BSIDE_BUNDLE_ID="dev.mabeck.bside.test"
export BSIDE_DIST_DIR="dist-test"
DATA_DIR="$HOME/Library/Application Support/$BSIDE_APP_NAME"

./scripts/bundle.sh
swift build -c release --product BSideSeed

# Quit a test copy still running an older build, or `open` would just focus it.
TEST_BINARY="$BSIDE_DIST_DIR/$BSIDE_APP_NAME.app/Contents/MacOS/BSide"
if pgrep -f "$TEST_BINARY" >/dev/null; then
    osascript -e "tell application id \"$BSIDE_BUNDLE_ID\" to quit" || true
    while pgrep -f "$TEST_BINARY" >/dev/null; do sleep 0.2; done
fi

if [ "$RESET" = 1 ]; then
    rm -rf "$DATA_DIR"
    defaults delete "$BSIDE_BUNDLE_ID" 2>/dev/null || true
fi
.build/release/BSideSeed "$BSIDE_APP_NAME"

open "$BSIDE_DIST_DIR/$BSIDE_APP_NAME.app"
